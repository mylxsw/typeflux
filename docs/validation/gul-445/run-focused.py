#!/usr/bin/env python3
"""One focused instrumented pass; no provider requests or personal documents."""
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT/'docs/validation/gul-445'
SUITES = 'AskFinalIntegrationTests AskAgentTurnTests AskAgentBindingTests AskApplicationAPITests AskPromptSectionsTests AskPromptBuilderTests AskQueueOwnershipTests AskFolderAuthorityTests AskBoundedFileToolsTests AskCommandJobLifecycleTests AskBuiltinWaveTests AskBrowserBackNavigationTests AskBrowserSitePolicyTests AskMCPToolsTests AskTypedContentIntegrationTests AskNotebookToolTests AskRecoveryNoticePresentationTests AskRecoverySafetyTests AskPermissionModeTests'
FILTERS = 'AskAgentToolsTests/testActualFileHostContinuationConflictAndRevocation|AskAgentToolsTests/testApprovedHostCommandClippingRetainsExitAndFinalSideEffect|AskAgentToolsTests/testHostCommandOnlyRunsThroughApprovedDispatch|AskAgentToolsTests/testNewStringsExistInEveryLanguage|AskEmbeddedBrowserToolTests/testGenericMutationsRequireFreshConsentEvenWithActPolicy|AskEmbeddedBrowserToolTests/testOffPermissionRefusesEveryPageAction|AskEmbeddedBrowserToolTests/testPausedOriginOrPolicyChangeCannotBorrowOldConsent|AskCommandJobTests/testCommandApprovalCopyAndUserTitlesDoNotExposeHandles|AskCommandJobTests/testLocalCancellationAndAccountDeviceChangesPreservePersistentFences|AskCommandJobTests/testPersistenceRestartInterruptedPrivacyCorruptionAndDiskFailure|AskCommandJobTests/testRealExcessOutputDrainsBothStreamsAndPreservesExitAndMarker|AskApprovalCopyTests/questionsNameTheActionAndItsObject|AskApprovalCopyTests/runCommandWarningMovedIntoAFact|AskApprovalCopyTests/exitCodesReadAsOutcomes'
command = ['make', 'coverage', 'SUITE='+SUITES, 'FILTER='+FILTERS]
started = time.monotonic()
with (OUT/'swift.log').open('w') as stream:
    result = subprocess.run(command,cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT)
record = dict(command=command,source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),elapsed_seconds=time.monotonic()-started,exit_code=result.returncode)
(OUT/'swift.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record),flush=True)
print((OUT/'swift.log').read_text()[-10000:])
raise SystemExit(result.returncode)
