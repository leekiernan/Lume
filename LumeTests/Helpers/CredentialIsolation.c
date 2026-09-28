//
//  CredentialIsolation.c
//  LumeTests
//
//  Swift has no load-time initializers, so this constructor is what points every
//  credential store at in-memory storage the moment the test bundle is loaded
//  into the host app — before any test can run. See CredentialIsolation.swift.
//

extern void lumeTestsInstallCredentialIsolation(void);

__attribute__((constructor)) static void lumeTestsIsolateCredentials(void) {
    lumeTestsInstallCredentialIsolation();
}
