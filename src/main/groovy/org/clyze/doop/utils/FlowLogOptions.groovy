package org.clyze.doop.utils

import groovy.transform.CompileStatic
import org.clyze.analysis.AnalysisOption

/**
 * The subset of analysis options that affect a FlowLog engine invocation,
 * parallel to {@link SouffleOptions}. Populated from the analysis option map so
 * {@link FlowLogScript} stays decoupled from the option framework.
 */
@CompileStatic
class FlowLogOptions {
    /**
     * Intern string columns as integer keys. Doop logic uses {@code ord(...)},
     * which flowlog-compiler only supports under {@code --str-intern}, so this
     * defaults to true and should stay on for Doop analyses.
     */
    boolean strIntern = true
    /** Enable Sideways Information Passing ({@code --sip}). */
    boolean sip
    /** Collect per-rule execution statistics ({@code -P}). */
    boolean profile
    /** Keep the generated Rust crate instead of cleaning it up ({@code --save-temps}). */
    boolean saveTemps
    /** Worker threads ({@code -w}) for the generated binary. */
    int jobs = 64

    FlowLogOptions(Map<String, AnalysisOption> options) {
        // Doop's ord(...) requires interning, so FLOWLOG_STR_INTERN defaults to true.
        this.strIntern  = options.FLOWLOG_STR_INTERN?.value as boolean
        this.sip        = options.FLOWLOG_SIP?.value as boolean
        this.profile    = options.FLOWLOG_PROFILE?.value as boolean
        this.saveTemps  = options.FLOWLOG_SAVE_TEMPS?.value as boolean
        if (options.FLOWLOG_JOBS?.value != null)
            this.jobs = options.FLOWLOG_JOBS.value as int
    }
}
