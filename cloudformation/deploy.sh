#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# deploy.sh — Deploy or update the WGS Pipeline CloudFormation stack
#
# Usage:
#   ./deploy.sh                    # Deploy with defaults
#   ./deploy.sh --delete           # Delete the stack
#   ./deploy.sh --status           # Check stack status
#   ./deploy.sh --outputs          # Show stack outputs
#   ./deploy.sh --connect          # Connect via SSM
# ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_NAME="nea-ehi-wgs-pipeline"
REGION="${AWS_DEFAULT_REGION:-ap-northeast-2}"
TEMPLATE="${SCRIPT_DIR}/wgs-pipeline-stack.yaml"
PROJECT_TAG="nea-ehi-wgs"

# Default VPC and subnet (ap-northeast-2)
DEFAULT_VPC="${VPC_ID:-vpc-xxxxxxxxx}"
DEFAULT_SUBNET="${SUBNET_ID:-subnet-xxxxxxxxx}"

# ─── Functions ───
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (none)          Deploy or update the stack"
    echo "  --delete        Delete the stack"
    echo "  --status        Show stack status"
    echo "  --outputs       Show stack outputs"
    echo "  --connect       Connect to instance via SSM"
    echo "  --logs          Show instance UserData logs via SSM"
    echo "  --upload-only   Upload scripts to S3 only (no stack update)"
    echo "  -h, --help      Show this help"
}

get_bucket_name() {
    local ACCOUNT_ID
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    echo "${PROJECT_TAG}-data-${ACCOUNT_ID}-${REGION}"
}

upload_scripts() {
    local BUCKET
    BUCKET=$(get_bucket_name)
    echo "[INFO] Uploading scripts to s3://${BUCKET}/scripts/"
    aws s3 sync "${SCRIPT_DIR}/scripts/" "s3://${BUCKET}/scripts/" \
        --region "${REGION}" \
        --exclude "*.swp" --exclude ".DS_Store"
    echo "[OK] Scripts uploaded"
}

get_instance_id() {
    aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${REGION}" \
        --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
        --output text 2>/dev/null
}

# ─── Parse arguments ───
ACTION="deploy"
if [ $# -gt 0 ]; then
    case "$1" in
        --delete)   ACTION="delete" ;;
        --status)   ACTION="status" ;;
        --outputs)  ACTION="outputs" ;;
        --connect)  ACTION="connect" ;;
        --logs)     ACTION="logs" ;;
        --upload-only) ACTION="upload" ;;
        -h|--help)  show_help; exit 0 ;;
        *)          echo "[ERROR] Unknown option: $1"; show_help; exit 1 ;;
    esac
fi

# ─── Execute ───
case "${ACTION}" in
    deploy)
        echo "============================================"
        echo " Deploying: ${STACK_NAME}"
        echo " Region:    ${REGION}"
        echo " Template:  ${TEMPLATE}"
        echo "============================================"

        # Validate template
        echo "[INFO] Validating CloudFormation template..."
        aws cloudformation validate-template \
            --template-body "file://${TEMPLATE}" \
            --region "${REGION}" > /dev/null
        echo "[OK] Template valid"

        # Check if stack exists
        STACK_EXISTS=$(aws cloudformation describe-stacks \
            --stack-name "${STACK_NAME}" \
            --region "${REGION}" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null || echo "DOES_NOT_EXIST")

        if [ "${STACK_EXISTS}" == "DOES_NOT_EXIST" ]; then
            echo "[INFO] Creating new stack..."
            aws cloudformation create-stack \
                --stack-name "${STACK_NAME}" \
                --template-body "file://${TEMPLATE}" \
                --region "${REGION}" \
                --capabilities CAPABILITY_NAMED_IAM \
                --parameters \
                    ParameterKey=VpcId,ParameterValue="${DEFAULT_VPC}" \
                    ParameterKey=SubnetId,ParameterValue="${DEFAULT_SUBNET}" \
                    ParameterKey=ProjectTag,ParameterValue="${PROJECT_TAG}" \
                --tags Key=Project,Value="${PROJECT_TAG}"

            echo "[INFO] Waiting for stack creation (this may take 30-60 min)..."
            echo "[INFO] Tools installation progress logged to /var/log/user-data.log on the instance"
            aws cloudformation wait stack-create-complete \
                --stack-name "${STACK_NAME}" \
                --region "${REGION}"
            echo "[OK] Stack created successfully"
        else
            echo "[INFO] Stack exists (status: ${STACK_EXISTS}). Updating..."

            # First ensure scripts are uploaded (bucket should already exist)
            upload_scripts 2>/dev/null || true

            aws cloudformation update-stack \
                --stack-name "${STACK_NAME}" \
                --template-body "file://${TEMPLATE}" \
                --region "${REGION}" \
                --capabilities CAPABILITY_NAMED_IAM \
                --parameters \
                    ParameterKey=VpcId,ParameterValue="${DEFAULT_VPC}" \
                    ParameterKey=SubnetId,ParameterValue="${DEFAULT_SUBNET}" \
                    ParameterKey=ProjectTag,ParameterValue="${PROJECT_TAG}" \
                --tags Key=Project,Value="${PROJECT_TAG}" \
            || echo "[INFO] No updates needed (stack is current)"

            echo "[OK] Update initiated"
        fi

        # Show outputs
        echo ""
        echo "[INFO] Stack outputs:"
        aws cloudformation describe-stacks \
            --stack-name "${STACK_NAME}" \
            --region "${REGION}" \
            --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
            --output table 2>/dev/null || echo "(stack still in progress)"

        # Upload scripts if bucket exists
        echo ""
        upload_scripts 2>/dev/null || echo "[INFO] Bucket not ready yet. Run: $0 --upload-only"
        ;;

    delete)
        echo "[WARN] Deleting stack: ${STACK_NAME}"
        echo "[WARN] S3 bucket will be RETAINED (DeletionPolicy=Retain)"
        read -p "Confirm? (y/N): " CONFIRM
        if [ "${CONFIRM}" != "y" ]; then
            echo "Cancelled."
            exit 0
        fi
        aws cloudformation delete-stack \
            --stack-name "${STACK_NAME}" \
            --region "${REGION}"
        echo "[INFO] Deletion initiated. Waiting..."
        aws cloudformation wait stack-delete-complete \
            --stack-name "${STACK_NAME}" \
            --region "${REGION}"
        echo "[OK] Stack deleted"
        ;;

    status)
        aws cloudformation describe-stacks \
            --stack-name "${STACK_NAME}" \
            --region "${REGION}" \
            --query 'Stacks[0].{Status:StackStatus,Created:CreationTime,Updated:LastUpdatedTime}' \
            --output table 2>/dev/null || echo "Stack does not exist"

        echo ""
        aws cloudformation describe-stack-events \
            --stack-name "${STACK_NAME}" \
            --region "${REGION}" \
            --query 'StackEvents[0:10].[Timestamp,ResourceStatus,LogicalResourceId,ResourceStatusReason]' \
            --output table 2>/dev/null || true
        ;;

    outputs)
        aws cloudformation describe-stacks \
            --stack-name "${STACK_NAME}" \
            --region "${REGION}" \
            --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
            --output table 2>/dev/null || echo "Stack does not exist"
        ;;

    connect)
        INSTANCE_ID=$(get_instance_id)
        if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" == "None" ]; then
            echo "[ERROR] No instance found. Is the stack deployed?"
            exit 1
        fi
        echo "[INFO] Connecting to ${INSTANCE_ID} via SSM..."
        aws ssm start-session --target "${INSTANCE_ID}" --region "${REGION}"
        ;;

    logs)
        INSTANCE_ID=$(get_instance_id)
        if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" == "None" ]; then
            echo "[ERROR] No instance found."
            exit 1
        fi
        echo "[INFO] Fetching user-data log from ${INSTANCE_ID}..."
        aws ssm send-command \
            --instance-ids "${INSTANCE_ID}" \
            --document-name "AWS-RunShellScript" \
            --parameters commands="tail -100 /var/log/user-data.log" \
            --region "${REGION}" \
            --output text \
            --query 'Command.CommandId'
        ;;

    upload)
        upload_scripts
        ;;
esac

echo ""
echo "Done."
