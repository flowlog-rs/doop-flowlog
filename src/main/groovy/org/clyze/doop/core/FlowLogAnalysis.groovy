package org.clyze.doop.core

import groovy.transform.CompileStatic
import groovy.transform.InheritConstructors
import groovy.util.logging.Log4j
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import org.clyze.doop.utils.FlowLogOptions
import org.clyze.doop.utils.FlowLogScript

import static org.apache.commons.io.FileUtils.deleteQuietly
import static org.apache.commons.io.FileUtils.sizeOfDirectory
import static org.apache.commons.io.FilenameUtils.getBaseName

/**
 * Runs a Doop analysis with the FlowLog engine over the hand-maintained
 * {@code flowlog-logic/} tree, parallel to {@link SouffleAnalysis}.
 *
 * The flow mirrors Souffle's — assemble the program by C-preprocessing and
 * concatenating logic files, generate facts, then hand off to the engine — but
 * it is trimmed to the subset {@code flowlog-logic/} actually provides:
 * {@code facts.dl}, {@code basic/basic.dl} and
 * {@code analyses/<name>/analysis.dl}. The statistics, information-flow, sanity
 * and open-programs addons live only under {@code souffle-logic/} and are not
 * part of the v1 FlowLog port, so they are intentionally omitted here.
 *
 * Unlike {@link SouffleAnalysis}, there is no separate compile/cache step:
 * {@link FlowLogScript#compileAndRun} performs compilation and execution in a
 * single {@code flowlog-compiler} invocation after the facts exist.
 */
@CompileStatic
@InheritConstructors
@Log4j
class FlowLogAnalysis extends DoopAnalysis {

    @Override
    void run() {
        File analysis = new File(outDir, "${name}.dl")
        deleteQuietly(analysis)
        analysis.createNewFile()

        initDatabase(analysis)
        mainAnalysis(analysis)

        File runtimeMetricsFile = File.createTempFile('Stats_Runtime', '.csv')
        log.debug "Using intermediate runtime metrics file: ${runtimeMetricsFile.canonicalPath}"
        runtimeMetricsFile.deleteOnExit()

        FlowLogScript script = new FlowLogScript(executor)
        FlowLogOptions flowlogOpts = new FlowLogOptions(options)

        log.info "[Task FACTS...]"
        generateFacts()
        log.info "[Task FACTS Done]"
        runtimeMetricsFile.append("fact generation time (sec)\t${factGenTime}\n")

        if (options.FACTS_ONLY.value) return

        if (!options.DRY_RUN.value) {
            // flowlog-compiler builds a native binary, then we run it; facts must exist first.
            script.compileAndRun(analysis, factsDir, outDir, flowlogOpts)
            runtimeMetricsFile.append("analysis compilation time (sec)\t${script.compilationTime}\n")
            runtimeMetricsFile.append("analysis execution time (sec)\t${script.executionTime}\n")
            int dbSize = (sizeOfDirectory(database) / 1024).intValue()
            runtimeMetricsFile.append("disk footprint (KB)\t${dbSize}\n")
        }

        Files.move(runtimeMetricsFile.toPath(),
                   new File(database, "Stats_Runtime.csv").toPath(),
                   StandardCopyOption.REPLACE_EXISTING)
    }

    void initDatabase(File analysis) {
        cpp.includeAtEnd("$analysis", "${Doop.flowlogLogicPath}/facts/facts.dl")
        handleImportDynamicFacts()
    }

    void mainAnalysis(File analysis) {
        cpp.includeAtEnd("$analysis", "${Doop.flowlogLogicPath}/basic/basic.dl")
        cpp.includeAtEnd("$analysis", "${Doop.flowlogAnalysesPath}/${getBaseName(analysis.name)}/analysis.dl")
        includeExtraLogic(analysis)
    }

    @Override
    void processRelation(String query, Closure outputLineProcessor) {
        query = query.replaceAll(":", "_")
        def file = new File(this.outDir, "database/${query}.csv")
        if (!file.exists()) throw new FileNotFoundException(file.canonicalPath)
        file.eachLine { outputLineProcessor.call(it) }
    }
}
