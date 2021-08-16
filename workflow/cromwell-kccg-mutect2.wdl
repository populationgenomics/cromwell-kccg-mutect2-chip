version 1.0

# =============================================================== #
# cromwell-kccg-mutect2                                           #
#                                                                 #
# This workflow runs the GATK4 Mutect2 somatic variant calling    #
# pipeline.                                                       #
#                                                                 #
# It has been adapted from the Broad Institute's pipeline for use #
# by the Kinghorn Centre for Clinical Genomics and the Garvan     #
# Institute for Medical Research.                                 #
#                                                                 #
# Author: Michael Geaghan (micgea)                                #
# Created: 2021/08/13                                             #
# =============================================================== #

## Copyright Broad Institute, 2017
##
## This WDL workflow runs GATK4 Mutect 2 on a single tumor-normal pair or on a single tumor sample,
## and performs additional filtering tasks.
##
## Main requirements/expectations :
## - One analysis-ready BAM file (and its index) for each sample
##
## Description of inputs:
##
## ** Runtime **
## gatk_docker: docker image to use for GATK 4 Mutect2
## preemptible: how many preemptions to tolerate before switching to a non-preemptible machine (on Google)
## max_retries: how many times to retry failed tasks -- very important on the cloud when there are transient errors
## gatk_override: (optional) local file or Google bucket path to a GATK 4 java jar file to be used instead of the GATK 4 jar
##                in the docker image.  This must be supplied when running in an environment that does not support docker
##                (e.g. SGE cluster on a Broad on-prem VM)
##
## ** Workflow options **
## intervals: genomic intervals (will be used for scatter)
## scatter_count: number of parallel jobs to generate when scattering over intervals
## m2_extra_args, m2_extra_filtering_args: additional arguments for Mutect2 calling and filtering (optional)
## split_intervals_extra_args: additional arguments for splitting intervals before scattering (optional)
## run_orientation_bias_mixture_model_filter: (optional) if true, filter orientation bias sites with the read orientation artifact mixture model.
##
## ** Primary inputs **
## ref_fasta, ref_fai, ref_dict: reference genome, index, and dictionary
## tumor_bam, tumor_bam_index: BAM and index for the tumor sample
## normal_bam, normal_bam_index: BAM and index for the normal sample
##
## ** Primary resources ** (optional but strongly recommended)
## pon, pon_idx: optional panel of normals (and its index) in VCF format containing probable technical artifacts (false positves)
## gnomad, gnomad_idx: optional database of known germline variants (and its index) (see http://gnomad.broadinstitute.org/downloads)
## variants_for_contamination, variants_for_contamination_idx: VCF of common variants (and its index)with allele frequencies for calculating contamination
##
## ** Secondary resources ** (for optional tasks)
## realignment_index_bundle: resource for FilterAlignmentArtifacts, which runs if and only if it is specified.  Generated by BwaMemIndexImageCreator.
##
## Outputs :
## - One VCF file and its index with primary filtering applied; a bamout.bam
##   file of reassembled reads if requested
##
## Cromwell version support
## - Successfully tested on v34
##
## LICENSING :
## This script is released under the WDL source code license (BSD-3) (see LICENSE in
## https://github.com/broadinstitute/wdl). Note however that the programs it calls may
## be subject to different licenses. Users are responsible for checking that they are
## authorized to run all programs before running this script. Please see the docker
## pages at https://hub.docker.com/r/broadinstitute/* for detailed licensing information
## pertaining to the included programs.

# import modules
import "modules/cram2bam.wdl" as Mod_Cram2Bam
import "modules/split_intervals.wdl" as Mod_SplitIntervals
import "modules/mutect2.wdl" as Mod_M2
import "modules/learn_rom.wdl" as Mod_LearnROM
import "modules/merge_vcfs.wdl" as Mod_MergeVCFs
import "modules/merge_bam_outs.wdl" as Mod_MergeBamOuts
import "modules/merge_stats.wdl" as Mod_MergeStats
import "modules/merge_pileup.wdl" as Mod_MergePileupSummaries
import "modules/calc_contam.wdl" as Mod_CalculateContamination
import "modules/filter.wdl" as Mod_Filter
import "modules/runtime.wdl" as Mod_RT

workflow Mutect2 {
    input {
      # Mutect2 inputs
      File? intervals
      File ref_fasta
      File ref_fai
      File ref_dict
      File tumor_reads
      File tumor_reads_index
      File? normal_reads
      File? normal_reads_index
      File? pon
      File? pon_idx
      Int scatter_count
      File? gnomad
      File? gnomad_idx
      File? variants_for_contamination
      File? variants_for_contamination_idx
      File? realignment_index_bundle
      String? realignment_extra_args
      Boolean? run_orientation_bias_mixture_model_filter
      String? m2_extra_args
      String? m2_extra_filtering_args
      String? split_intervals_extra_args
      Boolean? make_bamout
      Boolean? compress_vcfs
      File? gga_vcf
      File? gga_vcf_idx

      # runtime options
      String gatk_docker
      File? gatk_override
      String basic_bash_docker = "ubuntu:16.04"
      Int? preemptible
      Int? max_retries
      Int small_task_cpu = 2
      Int small_task_mem = 4
      Int small_task_disk = 100
      Int boot_disk_size = 12
      Int learn_read_orientation_mem = 8000
      Int filter_alignment_artifacts_mem = 9000

      # Use as a last resort to increase the disk given to every task in case of ill behaving data
      Int? emergency_extra_disk

      # These are multipliers to multipler inputs by to make sure we have enough disk to accommodate for possible output sizes
      # Large is for Bams/WGS vcfs
      # Small is for metrics/other vcfs
      Float large_input_to_output_multiplier = 2.25
      Float small_input_to_output_multiplier = 2.0
      Float cram_to_bam_multiplier = 6.0
    }

    Int preemptible_or_default = select_first([preemptible, 2])
    Int max_retries_or_default = select_first([max_retries, 2])

    Boolean compress = select_first([compress_vcfs, false])
    Boolean run_ob_filter = select_first([run_orientation_bias_mixture_model_filter, false])
    Boolean make_bamout_or_default = select_first([make_bamout, false])

    # Disk sizes used for dynamic sizing
    Int ref_size = ceil(size(ref_fasta, "GB") + size(ref_dict, "GB") + size(ref_fai, "GB"))
    Int tumor_reads_size = ceil(size(tumor_reads, "GB") + size(tumor_reads_index, "GB"))
    Int gnomad_vcf_size = if defined(gnomad) then ceil(size(gnomad, "GB")) else 0
    Int normal_reads_size = if defined(normal_reads) then ceil(size(normal_reads, "GB") + size(normal_reads_index, "GB")) else 0

    # If no tar is provided, the task downloads one from broads ftp server
    Int gatk_override_size = if defined(gatk_override) then ceil(size(gatk_override, "GB")) else 0

    # This is added to every task as padding, should increase if systematically you need more disk for every call
    Int disk_pad = 10 + gatk_override_size + select_first([emergency_extra_disk,0])

    # logic about output file names -- these are the names *without* .vcf extensions
    String output_basename = basename(basename(tumor_reads, ".bam"),".cram")  #hacky way to strip either .bam or .cram
    String unfiltered_name = output_basename + "-unfiltered"
    String filtered_name = output_basename + "-filtered"
    String output_vcf_name = output_basename + ".vcf"

    Int tumor_cram_to_bam_disk = ceil(tumor_reads_size * cram_to_bam_multiplier)
    Int normal_cram_to_bam_disk = ceil(normal_reads_size * cram_to_bam_multiplier)

    Runtime standard_runtime = {
        "gatk_docker": gatk_docker,
        "gatk_override": gatk_override,
        "max_retries": max_retries_or_default,
        "preemptible": preemptible_or_default,
        "cpu": small_task_cpu,
        "machine_mem": small_task_mem * 1000,
        "command_mem": small_task_mem * 1000 - 500,
        "disk": small_task_disk + disk_pad,
        "boot_disk_size": boot_disk_size
    }

    if (basename(tumor_reads) != basename(tumor_reads, ".cram")) {
        call Mod_Cram2Bam.CramToBam as TumorCramToBam {
            input:
                ref_fasta = ref_fasta,
                ref_fai = ref_fai,
                ref_dict = ref_dict,
                cram = tumor_reads,
                crai = tumor_reads_index,
                name = output_basename,
                disk_size_gb = tumor_cram_to_bam_disk
        }
    }

    if (defined(normal_reads)) {
        String normal_or_empty = select_first([normal_reads, ""])
        if (basename(normal_or_empty) != basename(normal_or_empty, ".cram")) {
            String normal_basename = basename(basename(normal_or_empty, ".bam"),".cram")
            call Mod_Cram2Bam.CramToBam as NormalCramToBam {
                input:
                    ref_fasta = ref_fasta,
                    ref_fai = ref_fai,
                    ref_dict = ref_dict,
                    cram = normal_reads,
                    crai = normal_reads_index,
                    name = normal_basename,
                    disk_size_gb = normal_cram_to_bam_disk
            }
        }
    }

    File tumor_bam = select_first([TumorCramToBam.output_bam, tumor_reads])
    File tumor_bai = select_first([TumorCramToBam.output_bai, tumor_reads_index])
    Int tumor_bam_size = ceil(size(tumor_bam, "GB") + size(tumor_bai, "GB"))

    File? normal_bam = if defined(normal_reads) then select_first([NormalCramToBam.output_bam, normal_reads]) else normal_reads
    File? normal_bai = if defined(normal_reads) then select_first([NormalCramToBam.output_bai, normal_reads_index]) else normal_reads_index
    Int normal_bam_size = if defined(normal_bam) then ceil(size(normal_bam, "GB") + size(normal_bai, "GB")) else 0

    Int m2_output_size = tumor_bam_size / scatter_count
    #TODO: do we need to change this disk size now that NIO is always going to happen (for the google backend only)
    Int m2_per_scatter_size = (tumor_bam_size + normal_bam_size) + ref_size + gnomad_vcf_size + m2_output_size + disk_pad

    call Mod_SplitIntervals.SplitIntervals {
        input:
            intervals = intervals,
            ref_fasta = ref_fasta,
            ref_fai = ref_fai,
            ref_dict = ref_dict,
            scatter_count = scatter_count,
            split_intervals_extra_args = split_intervals_extra_args,
            runtime_params = standard_runtime
    }

    # Test output
    output {
        File out_tumor_bam = tumor_bam
        File out_tumor_bai = tumor_bai
        Array[File] out_interval_files = SplitIntervals.interval_files
    }

    # scatter (subintervals in SplitIntervals.interval_files ) {
    #     call Mod_M2.M2 {
    #         input:
    #             intervals = subintervals,
    #             ref_fasta = ref_fasta,
    #             ref_fai = ref_fai,
    #             ref_dict = ref_dict,
    #             tumor_bam = tumor_bam,
    #             tumor_bai = tumor_bai,
    #             normal_bam = normal_bam,
    #             normal_bai = normal_bai,
    #             pon = pon,
    #             pon_idx = pon_idx,
    #             gnomad = gnomad,
    #             gnomad_idx = gnomad_idx,
    #             preemptible = preemptible,
    #             max_retries = max_retries,
    #             m2_extra_args = m2_extra_args,
    #             variants_for_contamination = variants_for_contamination,
    #             variants_for_contamination_idx = variants_for_contamination_idx,
    #             make_bamout = make_bamout_or_default,
    #             run_ob_filter = run_ob_filter,
    #             compress = compress,
    #             gga_vcf = gga_vcf,
    #             gga_vcf_idx = gga_vcf_idx,
    #             gatk_override = gatk_override,
    #             gatk_docker = gatk_docker,
    #             disk_space = m2_per_scatter_size
    #     }
    # }

    # Int merged_vcf_size = ceil(size(M2.unfiltered_vcf, "GB"))
    # Int merged_bamout_size = ceil(size(M2.output_bamOut, "GB"))

    # if (run_ob_filter) {
    #     call Mod_LearnROM.LearnReadOrientationModel {
    #         input:
    #             f1r2_tar_gz = M2.f1r2_counts,
    #             runtime_params = standard_runtime,
    #             mem = learn_read_orientation_mem
    #     }
    # }

    # call Mod_MergeVCFs.MergeVCFs {
    #     input:
    #         input_vcfs = M2.unfiltered_vcf,
    #         input_vcf_indices = M2.unfiltered_vcf_idx,
    #         output_name = unfiltered_name,
    #         compress = compress,
    #         runtime_params = standard_runtime
    # }

    # if (make_bamout_or_default) {
    #     call Mod_MergeBamOuts.MergeBamOuts {
    #         input:
    #             ref_fasta = ref_fasta,
    #             ref_fai = ref_fai,
    #             ref_dict = ref_dict,
    #             bam_outs = M2.output_bamOut,
    #             output_vcf_name = basename(MergeVCFs.merged_vcf, ".vcf"),
    #             runtime_params = standard_runtime,
    #             disk_space = ceil(merged_bamout_size * large_input_to_output_multiplier) + disk_pad,
    #     }
    # }

    # call Mod_MergeStats.MergeStats { input: stats = M2.stats, runtime_params = standard_runtime }

    # if (defined(variants_for_contamination)) {
    #     call Mod_MergePileupSummaries.MergePileupSummaries as MergeTumorPileups {
    #         input:
    #             input_tables = flatten(M2.tumor_pileups),
    #             output_name = output_basename,
    #             ref_dict = ref_dict,
    #             runtime_params = standard_runtime
    #     }

    #     if (defined(normal_bam)){
    #         call Mod_MergePileupSummaries.MergePileupSummaries as MergeNormalPileups {
    #             input:
    #                 input_tables = flatten(M2.normal_pileups),
    #                 output_name = output_basename,
    #                 ref_dict = ref_dict,
    #                 runtime_params = standard_runtime
    #         }
    #     }

    #     call Mod_CalculateContamination.CalculateContamination {
    #         input:
    #             tumor_pileups = MergeTumorPileups.merged_table,
    #             normal_pileups = MergeNormalPileups.merged_table,
    #             runtime_params = standard_runtime
    #     }
    # }

    # call Mod_Filter.Filter {
    #     input:
    #         ref_fasta = ref_fasta,
    #         ref_fai = ref_fai,
    #         ref_dict = ref_dict,
    #         intervals = intervals,
    #         unfiltered_vcf = MergeVCFs.merged_vcf,
    #         unfiltered_vcf_idx = MergeVCFs.merged_vcf_idx,
    #         output_name = filtered_name,
    #         compress = compress,
    #         mutect_stats = MergeStats.merged_stats,
    #         contamination_table = CalculateContamination.contamination_table,
    #         maf_segments = CalculateContamination.maf_segments,
    #         artifact_priors_tar_gz = LearnReadOrientationModel.artifact_prior_table,
    #         m2_extra_filtering_args = m2_extra_filtering_args,
    #         runtime_params = standard_runtime,
    #         disk_space = ceil(size(MergeVCFs.merged_vcf, "GB") * small_input_to_output_multiplier) + disk_pad
    # }

    # if (defined(realignment_index_bundle)) {
    #     call Mod_Filter.FilterAlignmentArtifacts {
    #         input:
    #             ref_fasta = ref_fasta,
    #             ref_fai = ref_fai,
    #             ref_dict = ref_dict,
    #             bam = tumor_bam,
    #             bai = tumor_bai,
    #             realignment_index_bundle = select_first([realignment_index_bundle]),
    #             realignment_extra_args = realignment_extra_args,
    #             compress = compress,
    #             output_name = filtered_name,
    #             input_vcf = Filter.filtered_vcf,
    #             input_vcf_idx = Filter.filtered_vcf_idx,
    #             runtime_params = standard_runtime,
    #             mem = filter_alignment_artifacts_mem
    #     }
    # }

    # output {
    #     File filtered_vcf = select_first([FilterAlignmentArtifacts.filtered_vcf, Filter.filtered_vcf])
    #     File filtered_vcf_idx = select_first([FilterAlignmentArtifacts.filtered_vcf_idx, Filter.filtered_vcf_idx])
    #     File filtering_stats = Filter.filtering_stats
    #     File mutect_stats = MergeStats.merged_stats
    #     File? contamination_table = CalculateContamination.contamination_table
    #     File? bamout = MergeBamOuts.merged_bam_out
    #     File? bamout_index = MergeBamOuts.merged_bam_out_index
    #     File? maf_segments = CalculateContamination.maf_segments
    #     File? read_orientation_model_params = LearnReadOrientationModel.artifact_prior_table
    # }
}