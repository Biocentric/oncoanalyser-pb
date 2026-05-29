//
// GPU-accelerated DNA alignment via NVIDIA Parabricks fq2bam.
//
// Mirrors the channel contract of read_alignment_dna so it is a drop-in swap
// for the BWA-MEM2 subworkflow. MarkDuplicates is NOT run here — Redux handles
// dedup downstream with HMF-tuned logic.
//
// Differences vs. the BWA-MEM2 path:
//   - FASTQ splitting (max_fastq_records) is intentionally disabled. On GPU,
//     splitting multiplies reference-load overhead with no throughput gain.
//   - fastp is only invoked when UMI processing is requested.
//

import Constants
import Utils

include { FASTP                  } from '../../../modules/local/fastp/main'
include { PARABRICKS_FQ2BAM      } from '../../../modules/local/parabricks/fq2bam/main'
include { SAMTOOLS_FIXMATE_SORT  } from '../../../modules/local/samtools/fixmate_sort/main'

workflow READ_ALIGNMENT_DNA_PARABRICKS {
    take:
    ch_inputs            // channel: [mandatory] [ meta ]

    genome_fasta         // channel: [mandatory] /path/to/genome_fasta
    genome_bwa_index     // channel: [mandatory] /path/to/bwa_index_dir

    umi_enable           // boolean: [mandatory] enable UMI pre-processing via fastp
    umi_location         //  string: [optional]  fastp UMI location
    umi_length           // numeric: [optional]  fastp UMI length
    umi_skip             // numeric: [optional]  fastp UMI skip

    main:
    ch_versions = Channel.empty()

    // Sort inputs, separate by tumor and normal (identical to bwa-mem2 path)
    ch_inputs_tumor_sorted = ch_inputs
        .branch { meta ->
            def has_existing = Utils.hasExistingInput(meta, Constants.INPUT.BAM_DNA_TUMOR)
            runnable: Utils.hasTumorDnaFastq(meta) && !has_existing
            skip: true
        }

    ch_inputs_normal_sorted = ch_inputs
        .branch { meta ->
            def has_existing = Utils.hasExistingInput(meta, Constants.INPUT.BAM_DNA_NORMAL)
            runnable: Utils.hasNormalDnaFastq(meta) && !has_existing
            skip: true
        }

    ch_inputs_donor_sorted = ch_inputs
        .branch { meta ->
            def has_existing = Utils.hasExistingInput(meta, Constants.INPUT.BAM_DNA_DONOR)
            runnable: Utils.hasDonorDnaFastq(meta) && !has_existing
            skip: true
        }

    // channel: [ meta_fastq, fastq_fwd, fastq_rev ]
    ch_fastq_inputs = Channel.empty()
        .mix(
            ch_inputs_tumor_sorted.runnable.map { meta -> [meta, Utils.getTumorDnaSample(meta), 'tumor'] },
            ch_inputs_normal_sorted.runnable.map { meta -> [meta, Utils.getNormalDnaSample(meta), 'normal'] },
            ch_inputs_donor_sorted.runnable.map { meta -> [meta, Utils.getDonorDnaSample(meta), 'donor'] },
        )
        .flatMap { meta, meta_sample, sample_type ->
            meta_sample
                .getAt(Constants.FileType.FASTQ)
                .collect { key, fps ->
                    def (library_id, lane) = key
                    def sample_id = meta_sample.getOrDefault('longitudinal_sample_id', meta_sample['sample_id'])

                    def meta_fastq = [
                        key: meta.group_id,
                        id: "${meta.group_id}_${sample_id}_${library_id}_${lane}",
                        sample_id: sample_id,
                        library_id: library_id,
                        lane: lane,
                        sample_type: sample_type,
                    ]

                    return [meta_fastq, fps['fwd'], fps['rev']]
                }
        }

    // Only run fastp for UMI pre-processing; no splitting on the GPU path.
    ch_fastqs_ready = Channel.empty()
    if (umi_enable) {
        FASTP(
            ch_fastq_inputs,
            0,  // max_fastq_records: always 0 for Parabricks path
            umi_location,
            umi_length,
            umi_skip,
        )
        ch_versions = ch_versions.mix(FASTP.out.versions)
        ch_fastqs_ready = FASTP.out.fastq
            .map { meta_fastq, fwd, rev -> [[*:meta_fastq, split: null], fwd, rev] }
    } else {
        ch_fastqs_ready = ch_fastq_inputs
            .map { meta_fastq, fwd, rev -> [[*:meta_fastq, split: null], fwd, rev] }
    }

    // channel: [ meta_pb, fastq_fwd, fastq_rev ]
    ch_fq2bam_inputs = ch_fastqs_ready
        .map { meta_fastq_ready, fwd, rev ->
            def meta_pb = [
                *:meta_fastq_ready,
                read_group: "${meta_fastq_ready.sample_id}.${meta_fastq_ready.library_id}.${meta_fastq_ready.lane}",
            ]
            return [meta_pb, fwd, rev]
        }

    // Step 1: GPU alignment. Emits ${id}.pb.bam (no mate CIGAR tags).
    PARABRICKS_FQ2BAM(
        ch_fq2bam_inputs,
        genome_fasta.map { [[id: 'fasta'], it] },
        genome_bwa_index.map { [[id: 'bwa_index'], it] },
    )

    // Step 2: add mate CIGAR + mate score tags. Emits ${id}.bam (REDUX-ready).
    // Split out as its own Nextflow process so post-process failures do not
    // invalidate the multi-hour GPU alignment cache.
    SAMTOOLS_FIXMATE_SORT(PARABRICKS_FQ2BAM.out.bam)

    ch_versions = ch_versions.mix(
        PARABRICKS_FQ2BAM.out.versions,
        SAMTOOLS_FIXMATE_SORT.out.versions,
    )

    // Reunite BAMs per sample — identical logic to bwa-mem2 path so downstream
    // Redux sees the same channel shape.
    ch_sample_fastq_counts = ch_fq2bam_inputs
        .map { meta_pb, _fwd, _rev ->
            def meta_count = [key: meta_pb.key, sample_type: meta_pb.sample_type]
            return [meta_count, meta_pb]
        }
        .groupTuple()
        .map { meta_count, metas -> [meta_count, metas.size()] }

    ch_bams_united = ch_sample_fastq_counts
        .cross(
            SAMTOOLS_FIXMATE_SORT.out.bam
                .map { meta_pb, bam, bai -> [[key: meta_pb.key, sample_type: meta_pb.sample_type], bam, bai] }
        )
        .map { count_tuple, bam_tuple ->
            def group_size = count_tuple[1]
            def (meta_bam, bam, bai) = bam_tuple
            def meta_group = [*:meta_bam]
            return tuple(groupKey(meta_group, group_size), bam, bai)
        }
        .groupTuple()
        .branch { meta_group, bams, bais ->
            assert ['tumor', 'normal', 'donor'].contains(meta_group.sample_type)
            tumor:  meta_group.sample_type == 'tumor'
            normal: meta_group.sample_type == 'normal'
            donor:  meta_group.sample_type == 'donor'
            placeholder: true
        }

    ch_bam_tumor_out = Channel.empty()
        .mix(
            WorkflowOncoanalyser.restoreMeta(ch_bams_united.tumor, ch_inputs),
            ch_inputs_tumor_sorted.skip.map { meta -> [meta, [], []] },
        )

    ch_bam_normal_out = Channel.empty()
        .mix(
            WorkflowOncoanalyser.restoreMeta(ch_bams_united.normal, ch_inputs),
            ch_inputs_normal_sorted.skip.map { meta -> [meta, [], []] },
        )

    ch_bam_donor_out = Channel.empty()
        .mix(
            WorkflowOncoanalyser.restoreMeta(ch_bams_united.donor, ch_inputs),
            ch_inputs_donor_sorted.skip.map { meta -> [meta, [], []] },
        )

    emit:
    dna_tumor  = ch_bam_tumor_out
    dna_normal = ch_bam_normal_out
    dna_donor  = ch_bam_donor_out
    versions   = ch_versions
}
