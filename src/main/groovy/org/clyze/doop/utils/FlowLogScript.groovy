package org.clyze.doop.utils

import groovy.transform.CompileStatic
import groovy.util.logging.Log4j
import org.clyze.utils.Executor
import org.clyze.utils.Helper

/**
 * Drives the FlowLog Datalog engine for Doop, parallel to {@link SouffleScript}
 * but targeting the {@code flowlog-compiler} binary.
 *
 * Like Souffle, this is a two-step backend. {@code flowlog-compiler} is a
 * build-time compiler: it generates a Rust crate and builds it with
 * {@code cargo} into a native executable, baking the fact directory ({@code -F})
 * and the output directory ({@code -D}) into that binary. It does <em>not</em>
 * run the analysis. The generated binary must then be executed (it only needs a
 * worker count, {@code -w N}); it reads the baked-in facts and writes the
 * output relations to the baked-in output directory. So {@link #compileAndRun}
 * performs both steps and times them separately ({@link #compilationTime} for
 * the flowlog-compiler build, {@link #executionTime} for the binary run),
 * mirroring Souffle's compile/run split.
 *
 * The compiler is located via the {@code FLOWLOG_BIN} environment variable (a
 * path to the {@code flowlog-compiler} executable); if unset it falls back to
 * {@code flowlog-compiler} on {@code PATH}.
 */
@Log4j
@CompileStatic
class FlowLogScript {

    static final String BIN_ENV_VAR = "FLOWLOG_BIN"
    static final String DEFAULT_BIN = "flowlog-compiler"
    static final String EXE_NAME = "analysis-binary"

    Executor executor
    long compilationTime = 0L
    long executionTime = 0L

    FlowLogScript(Executor executor) {
        this.executor = executor
    }

    /**
     * Resolve the flowlog-compiler executable: prefer {@code $FLOWLOG_BIN},
     * otherwise rely on {@code flowlog-compiler} being on {@code PATH}.
     */
    static String flowlogBinary() {
        String fromEnv = System.getenv(BIN_ENV_VAR)
        if (fromEnv) {
            File f = new File(fromEnv)
            if (!f.isFile())
                throw new RuntimeException("${BIN_ENV_VAR} is set but is not a file: ${fromEnv}")
            return f.canonicalPath
        }
        return DEFAULT_BIN
    }

    /**
     * Flatten the already-assembled analysis file through the C preprocessor one
     * final time into a throwaway flat {@code .dl} that flowlog-compiler reads,
     * returning that flattened file. Mirrors {@link SouffleScript#setScriptFileViaCPP}.
     */
    private File flattenViaCPP(File input, File outDir) {
        File output = File.createTempFile("flowlog_gen_", ".dl", outDir)
        CPreprocessor cpp = new CPreprocessor(executor)
        cpp.disableLineMarkers().enableLogOutput()
        cpp.preprocessIfExists(output.canonicalPath, input.canonicalPath)
        return output
    }

    /**
     * Compile the analysis to a native binary and then run it, recording each
     * step's wall time in {@link #compilationTime} / {@link #executionTime}.
     * Output relations are written as CSV files into {@code outDir/database}
     * (the directory baked into the binary at compile time via {@code -D}).
     *
     * @param origScriptFile the assembled (but not yet flattened) analysis file
     * @param factsDir       directory containing the input {@code .facts} files
     * @param outDir         the analysis output directory
     * @param options        FlowLog-specific invocation options
     */
    void compileAndRun(File origScriptFile, File factsDir, File outDir,
                       FlowLogOptions options) {

        File scriptFile = flattenViaCPP(origScriptFile, outDir)

        File db = new File(outDir, 'database')
        db.mkdirs()
        File exe = new File(outDir, EXE_NAME)

        // Step 1: compile. flowlog-compiler bakes the fact dir (-F) and output
        // dir (-D) into the generated binary (-o); it does NOT run the analysis.
        List<String> compileCmd = [flowlogBinary()]
        if (options.strIntern) compileCmd << '--str-intern'
        if (options.sip)       compileCmd << '--sip'
        if (options.profile)   compileCmd << '-P'
        if (options.saveTemps) compileCmd << '--save-temps'
        compileCmd << '-F' << factsDir.canonicalPath
        compileCmd << '-D' << db.canonicalPath
        compileCmd << '-o' << exe.canonicalPath
        compileCmd << scriptFile.canonicalPath

        log.info "Compiling FlowLog analysis"
        log.debug "FlowLog compile command: ${compileCmd.join(' ')}"
        compilationTime = Helper.timing {
            executor.execute(compileCmd) { log.info it }
        }
        log.info "FlowLog compilation time (sec): ${compilationTime}"

        // Step 2: run the generated binary. Fact/output paths are baked in, so
        // it only needs the worker count.
        List<String> runCmd = [exe.canonicalPath, '-w', options.jobs as String]
        log.info "Running FlowLog analysis (-w ${options.jobs})"
        log.debug "FlowLog run command: ${runCmd.join(' ')}"
        executionTime = Helper.timing {
            executor.execute(runCmd) { log.info it }
        }
        log.info "FlowLog analysis execution time (sec): ${executionTime}"
    }
}
