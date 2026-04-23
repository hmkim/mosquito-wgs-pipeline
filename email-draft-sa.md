**Subject:** HealthOmics Private Workflow — 5.4x BWA-mem2 Performance Degradation (Suspected SIMD Issue)

Hi [SA Name],

I hope you're doing well. We've been evaluating AWS HealthOmics Private Workflows for our Aedes aegypti WGS pipeline (GATK best practices) in ap-northeast-2, and we'd like to share a performance finding that significantly impacts our cost and runtime.

**Summary:**  
We ran the same pipeline (same Docker image, same data) on both EC2 (m5.2xlarge) and HealthOmics. The HealthOmics run completed successfully (Run ID: 6185205), but with significant performance differences:

- **BWA-mem2 alignment: 5.4x slower** (482 min vs. 90 min on EC2)
- **HaplotypeCaller: 1.8x slower** (1,080 min vs. 588 min on EC2)
- All other tasks: comparable (0.8x–1.2x)
- **Total wall-clock: 27.4 hours vs. 12.6 hours (2.2x slower)**

**Our analysis** (detailed in the attached report) points to two factors:
1. **SIMD instruction set degradation** — BWA-mem2 relies heavily on AVX-512 SIMD. The 5.4x slowdown is consistent with an AVX-512 → SSE4.1/4.2 fallback. We confirmed EC2 m5.2xlarge uses AVX-512BW, but cannot verify HealthOmics CPU capabilities since task-level stdout is not exposed in CloudWatch.
2. **Lower single-thread CPU performance** — HaplotypeCaller (single-threaded, no SIMD) is 1.8x slower, indicating a general CPU clock/microarchitecture gap.

**Cost Impact:**  
- HealthOmics total cost per sample: **~$10.46** (vs. $7.02 on EC2, **+49%**)
- BWA-mem2 + HaplotypeCaller account for **93%** of HealthOmics compute cost
- If both tasks ran at EC2-equivalent speed, HealthOmics would be **~$5.88/sample — 16% cheaper than EC2**

**We'd appreciate guidance on:**
1. What CPU/SIMD capabilities are available on `omics.m.*` instances in ap-northeast-2?
2. Is there a way to request instances with AVX-512 support?
3. Any plans to expose task stdout/stderr in CloudWatch for debugging?

Please find the full analysis in the attached report. Happy to set up a call to discuss further.

Best regards,  
[Your Name]  
NEA/EHI POC Team

**Attachment:** healthomics-performance-report.md
