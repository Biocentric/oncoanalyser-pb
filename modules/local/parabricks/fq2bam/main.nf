// Local Parabricks fq2bam module pinned to 4.0.0-1.
// GPU-accelerated BWA-MEM alignment + coordinate sort only, with
// `--no-markdups` (REDUX handles dedup downstream).
//
// IMPORTANT: this process emits *.pb.bam (Parabricks-native BAM, no mate
// CIGAR tags). REDUX requires mate CIGAR on every paired read; the
// SAMTOOLS_FIXMATE_SORT process downstream adds those. This split exists
// so a post-process bug doesn't invalidate the multi-hour GPU alignment
// cache — the alignment-only output is its own Nextflow task.

process PARABRICKS_FQ2BAM {
    tag "${meta.id}"
    label 'process_high'
    label 'process_gpu'
    label 'gpu_24gb'

    // Default symlink staging is fine — we explicitly `cp -L` the FASTA next
    // to the BWA index inside the script (the only file Parabricks requires
    // as a real copy). Forcing stageInMode 'copy' here would also duplicate
    // the input FASTQs (250+ GB on real WGS), which is wasteful.
    container "nvcr.io/nvidia/clara/clara-parabricks:4.0.0-1"

    input:
    tuple val(meta), path(reads_fwd), path(reads_rev)
    tuple val(meta2), path(fasta)
    tuple val(meta3), path(bwa_index)

    output:
    tuple val(meta), path("${meta.id}.pb.bam"), path("${meta.id}.pb.bam.bai"), emit: bam
    path "versions.yml"                                                      , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    if (workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1) {
        error("PARABRICKS_FQ2BAM does not support conda/mamba. Use docker or singularity.")
    }
    def args      = task.ext.args ?: ''
    def prefix    = task.ext.prefix ?: "${meta.id}"
    def num_gpus  = task.accelerator ? "--num-gpus ${task.accelerator.request}" : '--num-gpus 1'
    def rg_id     = meta.read_group ?: "${meta.sample_id}.${meta.library_id}.${meta.lane}"
    // Parabricks 4.0.0 fq2bam requires PU (Platform Unit) in the read group;
    // we reuse rg_id (sample.library.lane) since flowcell info isn't tracked.
    def rg_string = "@RG\\tID:${rg_id}\\tSM:${meta.sample_id}\\tLB:${meta.library_id}\\tPL:ILLUMINA\\tPU:${rg_id}"
    """
    INDEX=\$(find -L ./ -name "*.amb" | sed 's/\\.amb\$//')
    # -L follows the symlink so we copy the underlying FASTA, not the link.
    # Parabricks needs the FASTA to live in the same directory as the BWA index.
    cp -L ${fasta} \$INDEX

    pbrun fq2bam \\
        --ref \$INDEX \\
        --in-fq ${reads_fwd} ${reads_rev} "${rg_string}" \\
        --out-bam ${prefix}.pb.bam \\
        --no-markdups \\
        ${num_gpus} \\
        ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        parabricks: \$(pbrun version 2>&1 | grep -m1 '^pbrun:' | sed 's/^pbrun:[[:space:]]*//' || echo "4.0.0-1")
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.pb.bam
    touch ${prefix}.pb.bam.bai
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        parabricks: "4.0.0-1"
    END_VERSIONS
    """
}
