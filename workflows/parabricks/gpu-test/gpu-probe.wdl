version 1.0

task gpu_probe {
    input {
        String docker
        String accelerator_type
    }

    command {
        echo "=== GPU Probe ==="
        echo "acceleratorType: ~{accelerator_type}"
        nvidia-smi
        echo "=== Done ==="
    }

    output {
        File log = stdout()
    }

    runtime {
        docker: docker
        acceleratorType: accelerator_type
        acceleratorCount: 4
        cpu: 48
        memory: "192 GiB"
    }
}

workflow GpuProbe {
    input {
        String ecr_registry
        String accelerator_type
    }

    String docker = ecr_registry + "/parabricks:4.3.1-1"

    call gpu_probe {
        input:
            docker = docker,
            accelerator_type = accelerator_type
    }

    output {
        File log = gpu_probe.log
    }
}
