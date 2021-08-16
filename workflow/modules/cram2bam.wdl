version 1.0

task CramToBam {
    input {
      File ref_fasta
      File ref_fai
      File ref_dict
      # cram and crai must be optional since Normal cram is optional
      File? cram
      File? crai
      String name
      Int disk_size_gb
      Int mem_mb = 6000
    }

    # Calls samtools view to do the conversion
    command {
        # Set -e and -o says if any command I run fails in this script, make sure to return a failure
        set -e
        set -o pipefail

        samtools view -h -T ~{ref_fasta} ~{cram} |
            samtools view -b -o ~{name}.bam -
        samtools index -b ~{name}.bam
        mv ~{name}.bam.bai ~{name}.bai
    }

    runtime {
        docker: "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.3.3-1513176735"
        mem_mb: mem_mb
        disks: "local-disk " + disk_size_gb + " HDD"
    }

    output {
        File output_bam = "~{name}.bam"
        File output_bai = "~{name}.bai"
    }
}