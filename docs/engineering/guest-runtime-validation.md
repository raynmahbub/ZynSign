# Guest runtime validation report

Status: **Experimental / Unsupported for functional guest execution**. Staging and an in-process dyld probe are not application launch or sandbox isolation.

The staging path validates selected paths and avoids replacing an existing container; experimental code patches binaries, stages data slots, and attempts ad-hoc signing. The probe temporarily sets process-wide environment variables and invokes `dlopen`/`dlsym`. Guest constructors can execute during `dlopen`; restoring environment variables does not isolate code, protect other threads or recover from crashes. The probe no longer claims an absent entry symbol necessarily uses `LC_MAIN`. A mapped image or symbol is not evidence of a working guest, lifecycle, data isolation or termination.

No functional guest launch, dependency compatibility, process isolation, app extensions, notification delivery, background behavior, JIT entitlement, crash containment or cleanup guarantee has been demonstrated. Staged tweaks and dylibs are untrusted code in the host process. Data-slot deletion and metadata updates are not transactional. Do not load untrusted guests in the host process or claim LiveContainer parity.

A real implementation requires an explicit threat model, safe process/runtime design, platform entitlement and code-signing analysis, supported executable/dependency loading, lifecycle/termination and data-isolation design, and controlled device validation across OS versions. Tests must separate static parsing, staging, loader probing and actual launch; none of the new Swift tests have run here.
