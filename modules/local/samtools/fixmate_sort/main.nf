// Add mate CIGAR (MC) and mate score (MS) tags to a coord-sorted BAM, then
// re-coord-sort + index.
//
// Streamed three-stage pipe:
//   samtools collate -O -u  →  samtools fixmate -m -u  →  samtools sort
// collate (fast bucketing-based pair-grouping, not a full name-sort) is
// followed by fixmate which writes MC/MS tags, then a coordinate sort puts
// the BAM back in the order downstream tools expect.
//
// Lives as its own Nextflow process (rather than chained into PARABRICKS_FQ2BAM)
// so that bugs in the post-process don't invalidate the multi-hour GPU
// alignment cache — only this ~1-2h step has to re-run.
//
// Uses a modern samtools (1.19) where `-u` is supported on every step; the
// Parabricks container's bundled samtools is 1.10 and can't be relied on.

process SAMTOOLS_FIXMATE_SORT {
    tag "${meta.id}"
    label 'process_high'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/samtools:1.19--h50ea8bc_0' :
        'biocontainers/samtools:1.19--h50ea8bc_0' }"

    input:
    tuple val(meta), path(pb_bam), path(pb_bai)

    output:
    tuple val(meta), path("${meta.id}.bam"), path("${meta.id}.bam.bai"), emit: bam
    path "versions.yml"                                                , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args   = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    samtools collate -O -u -@ ${task.cpus} ${pb_bam} \\
        | samtools fixmate -m -u -@ ${task.cpus} - - \\
        | samtools sort -@ ${task.cpus} -T fixmate_coordsort -o ${prefix}.bam -
    samtools index -@ ${task.cpus} ${prefix}.bam

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        samtools: \$(samtools --version | sed -n '/^samtools / { s/^.* //p }' | head -n1)
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.bam
    touch ${prefix}.bam.bai
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        samtools: "1.19"
    END_VERSIONS
    """
}
