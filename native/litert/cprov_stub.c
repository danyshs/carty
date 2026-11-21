/* Stub for libGemmaModelConstraintProvider.so.
 * The vendored in-process runtime (liblitert-lm.so) carries a DT_NEEDED on a
 * companion libGemmaModelConstraintProvider.so + 3 versioned UND C-ABI symbols
 * that upstream does not ship in the release. These symbols are used ONLY for
 * constrained/tool-call decoding. For plain text generation they are never
 * exercised; Create returning NULL == "no constraint". CMakeLists re-exports
 * these under VERS_1.0 (cprov.map) so the versioned UNDs resolve at link time. */
void *LiteRtLmGemmaModelConstraintProvider_Create(void) { return 0; }
void *LiteRtLmGemmaModelConstraintProvider_CreateConstraintFromTools(void *a, void *b) {
  (void)a; (void)b; return 0;
}
void LiteRtLmGemmaModelConstraintProvider_Destroy(void *a) { (void)a; }
