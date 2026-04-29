#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# deploy-sentieon.sh — Deploy Sentieon DNAscope on HealthOmics
#
# Usage:
#   ./deploy-sentieon.sh                  # Show help
#   ./deploy-sentieon.sh --license-stack  # Deploy license server (new VPC by default)
#   ./deploy-sentieon.sh --build-image    # Build and push ECR image
#   ./deploy-sentieon.sh --setup-iam      # Create HealthOmics IAM role
#   ./deploy-sentieon.sh --register       # Register HealthOmics workflow
#   ./deploy-sentieon.sh --run            # Submit test run (SRR6063611)
#   ./deploy-sentieon.sh --status         # Check license server and run status
#   ./deploy-sentieon.sh --start-license  # Start license server daemon via SSM
#   ./deploy-sentieon.sh --stop-license   # Stop license server EC2 instance
#   ./deploy-sentieon.sh --delete         # Delete the license server stack
# ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REGION="${AWS_DEFAULT_REGION:-ap-southeast-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="nea-ehi-wgs-data-${ACCOUNT_ID}-${REGION}"
PROJECT_TAG="nea-ehi-wgs"
SENTIEON_VERSION="${SENTIEON_VERSION:-202503.03}"

LICENSE_STACK="nea-ehi-sentieon-license"
LICENSE_TEMPLATE="${PROJECT_ROOT}/cloudformation/sentieon-license-server-stack.yaml"
ECR_REPO="nea-ehi-sentieon"
ECR_TAG="omics-1"
WDL_NAME="sentieon-dnascope-mosquito.wdl"
WORKFLOW_ZIP="${SCRIPT_DIR}/sentieon-dnascope-workflow.zip"
OMICS_ROLE_NAME="nea-ehi-omics-sentieon-role"
WORKFLOW_NAME="sentieon-dnascope-mosquito"
RUN_INPUTS="${SCRIPT_DIR}/run-inputs-SRR6063611.json"
OMICS_CONFIG_NAME="nea-ehi-sentieon-vpc"

# VPC mode: default is to create a new dedicated VPC
# Set CREATE_NEW_VPC=false and provide VPC_ID/SUBNET_ID to use existing
CREATE_NEW_VPC="${CREATE_NEW_VPC:-true}"
EXISTING_VPC_ID="${VPC_ID:-}"
EXISTING_SUBNET_ID="${SUBNET_ID:-}"
NEW_VPC_CIDR="${NEW_VPC_CIDR:-10.100.0.0/16}"

# ─── Helper functions ─────────────────────────────────────

show_help() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Sentieon DNAscope deployment and management for HealthOmics."
    echo ""
    echo "Options:"
    echo "  --license-stack  Deploy or update license server CloudFormation stack"
    echo "  --build-image    Build Docker image and push to ECR"
    echo "  --setup-iam      Create HealthOmics IAM role"
    echo "  --register       Register HealthOmics workflow"
    echo "  --run            Submit a test run (SRR6063611)"
    echo "  --status         Show license server and recent run status"
    echo "  --start-license  Download license from S3 and start daemon"
    echo "  --stop-license   Stop license server EC2 instance (cost saving)"
    echo "  --delete         Delete the license server stack"
    echo "  -h, --help       Show this help"
    echo ""
    echo "Environment variables:"
    echo "  CREATE_NEW_VPC    Create dedicated VPC (default: true)"
    echo "  VPC_ID            Existing VPC ID (when CREATE_NEW_VPC=false)"
    echo "  SUBNET_ID         Existing Subnet ID (when CREATE_NEW_VPC=false)"
    echo "  NEW_VPC_CIDR      CIDR for new VPC (default: 10.100.0.0/16)"
    echo "  SENTIEON_VERSION  Sentieon version (default: 202503.03)"
}

get_stack_output() {
    local KEY="$1"
    aws cloudformation describe-stacks \
        --stack-name "${LICENSE_STACK}" --region "${REGION}" \
        --query "Stacks[0].Outputs[?OutputKey==\`${KEY}\`].OutputValue" \
        --output text 2>/dev/null
}

# ─── Actions ──────────────────────────────────────────────

deploy_license_stack() {
    if [ "${CREATE_NEW_VPC}" = "false" ]; then
        if [ -z "${EXISTING_VPC_ID}" ] || [ -z "${EXISTING_SUBNET_ID}" ]; then
            echo "[ERROR] When CREATE_NEW_VPC=false, VPC_ID and SUBNET_ID are required."
            exit 1
        fi
        echo "============================================"
        echo " Deploying: ${LICENSE_STACK} (existing VPC)"
        echo " Region:    ${REGION}"
        echo " VPC:       ${EXISTING_VPC_ID}"
        echo " Subnet:    ${EXISTING_SUBNET_ID}"
        echo "============================================"
    else
        echo "============================================"
        echo " Deploying: ${LICENSE_STACK} (new dedicated VPC)"
        echo " Region:    ${REGION}"
        echo " VPC CIDR:  ${NEW_VPC_CIDR}"
        echo "============================================"
    fi

    echo "[INFO] Validating CloudFormation template..."
    aws cloudformation validate-template \
        --template-body "file://${LICENSE_TEMPLATE}" \
        --region "${REGION}" > /dev/null
    echo "[OK] Template valid"

    CFN_PARAMS=(
        "ParameterKey=CreateNewVpc,ParameterValue=${CREATE_NEW_VPC}"
        "ParameterKey=ExistingVpcId,ParameterValue=${EXISTING_VPC_ID}"
        "ParameterKey=ExistingSubnetId,ParameterValue=${EXISTING_SUBNET_ID}"
        "ParameterKey=NewVpcCidr,ParameterValue=${NEW_VPC_CIDR}"
        "ParameterKey=DataBucketName,ParameterValue=${BUCKET}"
        "ParameterKey=SentieonVersion,ParameterValue=${SENTIEON_VERSION}"
        "ParameterKey=ProjectTag,ParameterValue=${PROJECT_TAG}"
    )

    STACK_STATUS=$(aws cloudformation describe-stacks \
        --stack-name "${LICENSE_STACK}" --region "${REGION}" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

    if [ "${STACK_STATUS}" == "DOES_NOT_EXIST" ]; then
        echo "[INFO] Creating new stack..."
        aws cloudformation create-stack \
            --stack-name "${LICENSE_STACK}" \
            --template-body "file://${LICENSE_TEMPLATE}" \
            --region "${REGION}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters "${CFN_PARAMS[@]}" \
            --tags Key=Project,Value="${PROJECT_TAG}"

        echo "[INFO] Waiting for stack creation..."
        aws cloudformation wait stack-create-complete \
            --stack-name "${LICENSE_STACK}" --region "${REGION}"
        echo "[OK] Stack created successfully"
    else
        echo "[INFO] Stack exists (status: ${STACK_STATUS}). Updating..."
        aws cloudformation update-stack \
            --stack-name "${LICENSE_STACK}" \
            --template-body "file://${LICENSE_TEMPLATE}" \
            --region "${REGION}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters "${CFN_PARAMS[@]}" \
            --tags Key=Project,Value="${PROJECT_TAG}" \
        || echo "[INFO] No updates needed"

        echo "[INFO] Waiting for stack update..."
        aws cloudformation wait stack-update-complete \
            --stack-name "${LICENSE_STACK}" --region "${REGION}" 2>/dev/null || true
    fi

    LICENSE_IP=$(get_stack_output "LicenseServerPrivateIp")
    VPC_USED=$(get_stack_output "VpcId")
    SUBNET_IDS=$(get_stack_output "OmicsSubnetIds")
    echo ""
    echo "============================================"
    echo " License Server Deployed"
    echo ""
    echo " VPC:            ${VPC_USED}"
    echo " Subnets:        ${SUBNET_IDS}"
    echo " Private IP:     ${LICENSE_IP}"
    echo " License Addr:   ${LICENSE_IP}:8990"
    echo " SSM Connect:    $(get_stack_output 'SSMSessionCommand')"
    echo " S3 License:     $(get_stack_output 'S3LicensePath')"
    echo ""
    echo " NEXT STEP: Send this IP to Don Freed (Sentieon)"
    echo "   Email: don.freed@sentieon.com"
    echo "   Host:  ${LICENSE_IP}"
    echo "   For:   NEA-EHI project, account ${ACCOUNT_ID}, ${REGION}"
    echo "============================================"
}

build_and_push_image() {
    ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"

    echo "[INFO] Ensuring ECR repository exists..."
    aws ecr describe-repositories --repository-names "${ECR_REPO}" \
        --region "${REGION}" > /dev/null 2>&1 || \
        aws ecr create-repository --repository-name "${ECR_REPO}" \
            --region "${REGION}" \
            --image-scanning-configuration scanOnPush=true \
            --tags Key=Project,Value="${PROJECT_TAG}"

    echo "[INFO] Logging in to ECR..."
    aws ecr get-login-password --region "${REGION}" | \
        docker login --username AWS --password-stdin \
        "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

    echo "[INFO] Building Docker image (Sentieon ${SENTIEON_VERSION})..."
    docker build --platform linux/amd64 \
        --build-arg SENTIEON_VERSION="${SENTIEON_VERSION}" \
        -t "${ECR_REPO}:${ECR_TAG}" \
        -f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"

    echo "[INFO] Pushing to ECR..."
    docker tag "${ECR_REPO}:${ECR_TAG}" "${ECR_URI}:${ECR_TAG}"
    docker push "${ECR_URI}:${ECR_TAG}"

    echo "[INFO] Setting ECR repository policy for HealthOmics..."
    aws ecr set-repository-policy \
        --repository-name "${ECR_REPO}" \
        --region "${REGION}" \
        --policy-text "file://${SCRIPT_DIR}/omics-ecr-policy.json"

    echo "[OK] Image pushed: ${ECR_URI}:${ECR_TAG}"
}

setup_iam_role() {
    echo "[INFO] Setting up HealthOmics IAM role: ${OMICS_ROLE_NAME}"

    TRUST_POLICY="${SCRIPT_DIR}/../gatk/omics-trust-policy.json"
    TMP_TRUST=$(mktemp /tmp/sentieon-trust-XXXXXX.json)
    sed "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g" "${TRUST_POLICY}" > "${TMP_TRUST}"

    aws iam get-role --role-name "${OMICS_ROLE_NAME}" > /dev/null 2>&1 || \
        aws iam create-role \
            --role-name "${OMICS_ROLE_NAME}" \
            --assume-role-policy-document "file://${TMP_TRUST}"
    rm -f "${TMP_TRUST}"

    TMP_PERMS=$(mktemp /tmp/sentieon-perms-XXXXXX.json)
    sed \
        -e "s/<BUCKET>/${BUCKET}/g" \
        -e "s/<REGION>/${REGION}/g" \
        -e "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g" \
        "${SCRIPT_DIR}/omics-permissions-policy.json" > "${TMP_PERMS}"

    aws iam put-role-policy \
        --role-name "${OMICS_ROLE_NAME}" \
        --policy-name "sentieon-omics-permissions" \
        --policy-document "file://${TMP_PERMS}"
    rm -f "${TMP_PERMS}"

    echo "[OK] IAM role configured: ${OMICS_ROLE_NAME}"
}

register_workflow() {
    echo "[INFO] Packaging WDL workflow..."
    cd "${SCRIPT_DIR}"
    rm -f "${WORKFLOW_ZIP}"
    zip -j "${WORKFLOW_ZIP}" "${WDL_NAME}"

    echo "[INFO] Registering HealthOmics workflow: ${WORKFLOW_NAME}"
    WORKFLOW_ID=$(aws omics create-workflow \
        --name "${WORKFLOW_NAME}" \
        --engine WDL \
        --definition-zip "fileb://${WORKFLOW_ZIP}" \
        --main "${WDL_NAME}" \
        --region "${REGION}" \
        --query 'id' --output text)

    echo "${WORKFLOW_ID}" > "${SCRIPT_DIR}/.workflow-id"
    echo "[OK] Workflow registered: ID = ${WORKFLOW_ID}"

    echo "[INFO] Waiting for workflow to become ACTIVE..."
    while true; do
        STATUS=$(aws omics get-workflow --id "${WORKFLOW_ID}" --region "${REGION}" \
            --query 'status' --output text)
        echo "  Status: ${STATUS}"
        if [ "${STATUS}" == "ACTIVE" ]; then break; fi
        if [ "${STATUS}" == "FAILED" ]; then
            echo "[ERROR] Workflow creation failed!"
            aws omics get-workflow --id "${WORKFLOW_ID}" --region "${REGION}" \
                --query '{Status:status,Error:statusMessage}' --output table
            exit 1
        fi
        sleep 10
    done
    echo "[OK] Workflow is ACTIVE"
}

submit_test_run() {
    LICENSE_IP=$(get_stack_output "LicenseServerPrivateIp")
    if [ -z "${LICENSE_IP}" ] || [ "${LICENSE_IP}" == "None" ]; then
        echo "[ERROR] License server IP not found. Deploy the license stack first."
        exit 1
    fi

    OMICS_SG_ID=$(get_stack_output "OmicsTaskSecurityGroupId")
    OMICS_SUBNET_IDS=$(get_stack_output "OmicsSubnetIds")

    WORKFLOW_ID=$(cat "${SCRIPT_DIR}/.workflow-id" 2>/dev/null || \
        aws omics list-workflows --region "${REGION}" \
            --query "items[?name=='${WORKFLOW_NAME}'] | sort_by(@, &creationTime) | [-1].id" \
            --output text)

    if [ -z "${WORKFLOW_ID}" ] || [ "${WORKFLOW_ID}" == "None" ]; then
        echo "[ERROR] No workflow found. Register with --register first."
        exit 1
    fi

    ROLE_ARN=$(aws iam get-role --role-name "${OMICS_ROLE_NAME}" \
        --query 'Role.Arn' --output text)

    TMP_INPUTS=$(mktemp /tmp/sentieon-run-inputs-XXXXXX.json)
    sed \
        -e "s/<BUCKET>/${BUCKET}/g" \
        -e "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g" \
        -e "s/<REGION>/${REGION}/g" \
        -e "s/<LICENSE_SERVER_PRIVATE_IP>/${LICENSE_IP}/g" \
        "${RUN_INPUTS}" > "${TMP_INPUTS}"

    if grep -q '<' "${TMP_INPUTS}"; then
        echo "[ERROR] Unreplaced placeholders in run inputs:"
        grep '<' "${TMP_INPUTS}"
        rm -f "${TMP_INPUTS}"
        exit 1
    fi

    RUN_NAME="SRR6063611-sentieon-dnascope-$(date +%Y%m%d-%H%M)"
    echo "[INFO] Submitting HealthOmics run: ${RUN_NAME}"
    echo "  Workflow ID:   ${WORKFLOW_ID}"
    echo "  License:       ${LICENSE_IP}:8990"
    echo "  VPC Subnets:   ${OMICS_SUBNET_IDS}"
    echo "  VPC SG:        ${OMICS_SG_ID}"

    RUN_ID=$(aws omics start-run \
        --workflow-id "${WORKFLOW_ID}" \
        --role-arn "${ROLE_ARN}" \
        --name "${RUN_NAME}" \
        --output-uri "s3://${BUCKET}/omics-output/sentieon/" \
        --parameters "file://${TMP_INPUTS}" \
        --storage-type DYNAMIC \
        --log-level ALL \
        --networking-mode VPC \
        --configuration-name "${OMICS_CONFIG_NAME}" \
        --region "${REGION}" \
        --query 'id' --output text)

    rm -f "${TMP_INPUTS}"

    echo "[OK] Run submitted: ID = ${RUN_ID}"
    echo ""
    echo "Monitor with:"
    echo "  aws omics get-run --id ${RUN_ID} --region ${REGION}"
    echo "  aws omics list-run-tasks --id ${RUN_ID} --region ${REGION}"
}

show_status() {
    echo "=== License Server Status ==="
    INSTANCE_ID=$(get_stack_output "LicenseServerInstanceId")
    if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" == "None" ]; then
        echo "License server stack not found."
    else
        aws ec2 describe-instance-status --instance-ids "${INSTANCE_ID}" \
            --region "${REGION}" \
            --query 'InstanceStatuses[0].{State:InstanceState.Name,SystemStatus:SystemStatus.Status,InstanceStatus:InstanceStatus.Status}' \
            --output table 2>/dev/null || echo "Instance ${INSTANCE_ID} not running"

        LICENSE_IP=$(get_stack_output "LicenseServerPrivateIp")
        echo "  VPC:             $(get_stack_output 'VpcId')"
        echo "  Private IP:      ${LICENSE_IP}"
        echo "  License Address: ${LICENSE_IP}:8990"
    fi

    echo ""
    echo "=== ECR Repository ==="
    aws ecr describe-images --repository-name "${ECR_REPO}" --region "${REGION}" \
        --query 'imageDetails[*].{Tags:imageTags[0],Pushed:imagePushedAt,Size:imageSizeInBytes}' \
        --output table 2>/dev/null || echo "ECR repository not found"

    echo ""
    echo "=== Recent HealthOmics Runs ==="
    aws omics list-runs --region "${REGION}" \
        --query "items[?contains(name,'sentieon')] | [0:5].[id,name,status,startTime]" \
        --output table 2>/dev/null || echo "No runs found"
}

start_license_daemon() {
    INSTANCE_ID=$(get_stack_output "LicenseServerInstanceId")
    if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" == "None" ]; then
        echo "[ERROR] License server instance not found."
        exit 1
    fi

    INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
        --region "${REGION}" \
        --query 'Reservations[0].Instances[0].State.Name' --output text)

    if [ "${INSTANCE_STATE}" == "stopped" ]; then
        echo "[INFO] Starting EC2 instance ${INSTANCE_ID}..."
        aws ec2 start-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" > /dev/null
        aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${REGION}"
        echo "[OK] Instance running"
        sleep 10
    fi

    echo "[INFO] Starting license daemon via SSM..."
    COMMAND_ID=$(aws ssm send-command \
        --instance-ids "${INSTANCE_ID}" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["bash /usr/local/bin/sentieon-license-start.sh"]' \
        --region "${REGION}" \
        --query 'Command.CommandId' --output text)

    echo "[INFO] Waiting for command to complete (ID: ${COMMAND_ID})..."
    while true; do
        CMD_STATUS=$(aws ssm get-command-invocation \
            --command-id "${COMMAND_ID}" \
            --instance-id "${INSTANCE_ID}" \
            --region "${REGION}" \
            --query 'Status' --output text 2>/dev/null || echo "Pending")
        if [[ "${CMD_STATUS}" == "Success" || "${CMD_STATUS}" == "Failed" || "${CMD_STATUS}" == "TimedOut" ]]; then
            break
        fi
        echo "  SSM Status: ${CMD_STATUS}..."
        sleep 5
    done

    aws ssm get-command-invocation \
        --command-id "${COMMAND_ID}" \
        --instance-id "${INSTANCE_ID}" \
        --region "${REGION}" \
        --query '{Status:Status,Output:StandardOutputContent}' \
        --output table 2>/dev/null || echo "[WARN] Check SSM command output manually"
}

stop_license_instance() {
    INSTANCE_ID=$(get_stack_output "LicenseServerInstanceId")
    if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" == "None" ]; then
        echo "[ERROR] License server instance not found."
        exit 1
    fi

    echo "[INFO] Stopping license server instance ${INSTANCE_ID}..."
    aws ec2 stop-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" > /dev/null
    echo "[OK] Instance stopping (EBS cost only: ~\$0.01/hr)"
}

delete_stack() {
    echo "[WARN] Deleting stack: ${LICENSE_STACK} in ${REGION}"
    echo "[WARN] This will delete the VPC, subnets, and license server."
    read -p "Confirm? (y/N): " CONFIRM
    if [ "${CONFIRM}" != "y" ]; then
        echo "Cancelled."
        exit 0
    fi
    aws cloudformation delete-stack \
        --stack-name "${LICENSE_STACK}" --region "${REGION}"
    echo "[INFO] Deletion initiated. Waiting..."
    aws cloudformation wait stack-delete-complete \
        --stack-name "${LICENSE_STACK}" --region "${REGION}"
    echo "[OK] Stack deleted"
}

# ─── Main ─────────────────────────────────────────────────

if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

case "$1" in
    --license-stack)  deploy_license_stack ;;
    --build-image)    build_and_push_image ;;
    --setup-iam)      setup_iam_role ;;
    --register)       register_workflow ;;
    --run)            submit_test_run ;;
    --status)         show_status ;;
    --start-license)  start_license_daemon ;;
    --stop-license)   stop_license_instance ;;
    --delete)         delete_stack ;;
    -h|--help)        show_help ;;
    *)                echo "[ERROR] Unknown option: $1"; show_help; exit 1 ;;
esac

echo ""
echo "Done."
