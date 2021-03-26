#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

project_dir = projectDir
publish_dev = file(params.publish_dev)

process dequote_tree {
    /**
    * Dequotes tree
    * @input tree
    */

    input:
    path tree

    output:
    path "${tree.baseName}.dequote.tree"

    script:
    """
    sed "s/'//g" ${tree} > "${tree.baseName}.dequote.tree"
    """
}

process extract_tips_fasta {
    /**
    * Extracts fasta corresponding to tips in the tree
    * @input fasta, tree
    */
    label 'retry_increasing_mem'

    input:
    path fasta
    path tree

    output:
    path "${fasta.baseName}.tips.fasta", emit: fasta
    path "${fasta.baseName}.new.fasta", emit: to_add

    script:
    """
    fastafunk extract \
        --in-fasta ${fasta} \
        --in-tree ${tree} \
        --out-fasta "${fasta.baseName}.tips.fasta" \
        --reject-fasta "${fasta.baseName}.new.fasta"
    """
}

process add_reference_to_fasta {
    /**
    * Creates a new fasta with reference first
    * @input fasta
    */

    input:
    path fasta

    output:
    path "${fasta.baseName}.with_reference.fasta"

    script:
    """
    cat ${reference} > "${fasta.baseName}.with_reference.fasta"
    cat ${fasta} >> "${fasta.baseName}.with_reference.fasta"
    """
}

process fasta_to_vcf {
    /**
    * Makes VCF for usher
    * @input fasta
    */
    memory { 30.0.GB + 10.GB * task.attempt }
    errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
    maxRetries = 2


    input:
    path fasta

    output:
    path "${fasta.baseName}.vcf"

    script:
    """
    faToVcf ${fasta} ${fasta.baseName}.vcf
    """
}

process usher_start_tree {
    /**
    * Makes usher mutation annotated tree
    * @input tree, vcf
    */
    memory { 30.0.GB + 10.GB * task.attempt }
    errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
    maxRetries = 1
    cpus 8

    publishDir "${publish_dev}", pattern: "trees/*.USH.tsv", mode: 'copy'
    publishDir "${publish_dev}", pattern: "trees/*.pb", mode: 'copy'

    input:
    path vcf
    path tree

    output:
    path "trees/${tree.baseName}.USH.tree", emit: tree
    path "trees/${tree.baseName}.${params.date}.pb", emit: protobuf

    script:
    """
    mkdir -p trees
    usher --tree ${tree} \
          --vcf ${vcf} \
          --threads ${task.cpus} \
          --save-mutation-annotated-tree trees/${tree.baseName}.${params.date}.pb \
          --collapse-tree \
          --write-uncondensed-final-tree \
          --outdir trees

    cp trees/uncondensed-final-tree.nh trees/${tree.baseName}.USH.tree
    """
}

process usher_update_tree {
    /**
    * Makes usher mutation annotated tree
    * @input tree, vcf
    */

    maxForks 1
    memory { 30.0.GB + 10.GB * task.attempt }
    errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'ignore' }
    maxRetries = 2
    cpus 8

    input:
    path vcf
    path protobuf

    output:
    path "trees/${protobuf.baseName}.USH.tree", emit: tree
    path "*.pb", emit: protobuf

    script:
    """
    mkdir -p trees
    usher -i ${protobuf} \
          --vcf ${vcf} \
          --threads ${task.cpus} \
          --save-mutation-annotated-tree ${protobuf.baseName}.${params.date}.pb \
          --collapse-tree \
          --write-uncondensed-final-tree \
          --outdir trees
    if [ \$? -eq 0 ]; then
        cp ${protobuf.baseName}.${params.date}.pb ${protobuf}
        cp trees/uncondensed-final-tree.nh trees/${protobuf.baseName}.USH.tree
    fi
    """
}

process root_tree {
    /**
    * Roots tree with WH04
    * @input tree
    */

    publishDir "${publish_dev}", pattern: "trees/*.tree", mode: 'copy'

    input:
    path tree

    output:
    path "${tree.baseName}.rooted.tree"

    script:
    """
    jclusterfunk reroot \
        --format newick \
        -i ${tree} \
        -o ${tree.baseName}.rooted.tree \
        --outgroup Wuhan/WH04/2020
    #touch ${tree.baseName}.rooted.tree
    """
}

process announce_tree_complete {
    /**
    * Announces usher updated tree
    * @input tree
    */

    input:
    path tree

    output:
    path "usher_tree.json"

    script:
        if (params.webhook)
            """
            echo "{{'text':'" > usher_tree.json
            echo "*Phylopipe2.0: Usher expanded tree for ${params.date} complete*\\n" >> usher_tree.json
            echo "'}}" >> usher_tree.json

            echo 'webhook ${params.webhook}'

            curl -X POST -H "Content-type: application/json" -d @usher_tree.json ${params.webhook}
            """
        else
           """
           touch "usher_tree.json"
           """
}

reference = file(params.reference_fasta)

workflow iteratively_update_tree {
    take:
        fasta
        protobuf
    main:
        fasta.splitFasta( by: params.chunk_size, file: true ).set{ fasta_chunks }
        add_reference_to_fasta(fasta_chunks)
        fasta_to_vcf(add_reference_to_fasta.out)

        usher_update_tree(fasta_to_vcf.out, protobuf)
        final_tree = usher_update_tree.out.tree.last()
    emit:
        tree = final_tree
}


workflow build_full_tree {
    take:
        fasta
        newick_tree
    main:
        dequote_tree(newick_tree)
        extract_tips_fasta(fasta, dequote_tree.out)
        add_reference_to_fasta(extract_tips_fasta.out.fasta)
        fasta_to_vcf(add_reference_to_fasta.out)
        usher_start_tree(fasta_to_vcf.out,dequote_tree.out)
        iteratively_update_tree(extract_tips_fasta.out.to_add,usher_start_tree.out.protobuf)
        root_tree(iteratively_update_tree.out.tree)
        announce_tree_complete(root_tree.out)
    emit:
        tree = root_tree.out
}

workflow update_full_tree {
    take:
        fasta
        newick_tree
        protobuf
    main:
        dequote_tree(newick_tree)
        extract_tips_fasta(fasta, dequote_tree.out)
        iteratively_update_tree(extract_tips_fasta.out.to_add,protobuf)
        root_tree(iteratively_update_tree.out.tree)
        announce_tree_complete(root_tree.out)
    emit:
        tree = root_tree.out
}

workflow {
    fasta = file(params.fasta)
    newick_tree = file(params.newick_tree)

    build_full_tree(fasta,newick_tree)
}