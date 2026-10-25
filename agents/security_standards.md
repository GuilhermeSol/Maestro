# iOS Security Standards

This file is a **reference** for every agent. It gives the rule IDs, the data
classes and the severity levels. The security **flow** is in CLAUDE.md
(Security — Basic Scan) and in `security_agent.md`. Read this file when you
need a rule or a level. Cite the rule ID (`SEC-<AREA>-NN`) in each finding.

**Sources.** The rules follow these published standards. Re-check the
control and CWE IDs against the current publications when you update
this file.

| Source | Use |
|---|---|
| OWASP MASVS v2 (`MASVS-<CATEGORY>-N`) | What a secure mobile app must achieve |
| OWASP MASTG | How to test each control |
| OWASP Mobile Top 10 (2024) | Risk ranking |
| MITRE CWE (`CWE-N`) | Weakness names for findings |
| NIST SSDF, SP 800-218 | Secure development process |
| Apple Platform Security and developer documentation | Platform controls (Keychain, Data Protection, ATS, privacy manifests) |
| IETF RFC 8252, RFC 7636 | OAuth 2.0 for native apps, PKCE |

**Rule words.** MUST and MUST NOT are mandatory. SHOULD is the default.
An agent that does not follow a SHOULD records the reason.

---

## 1. Data classification

Use these classes when you judge a change. The highest class in a flow sets
the rules for that flow.

| Class | Examples | Storage | Transport | Logs and analytics | Backup |
|---|---|---|---|---|---|
| **Public** | App version, public catalogue | Any | TLS | Allowed | Allowed |
| **Internal** | Feature flags, non-personal settings | App container | TLS | No user identifiers | Allowed |
| **Personal** | Anything about an identifiable person: name, email, phone, device or user ID, location, health, biometrics, finance, children's data, special categories under GDPR Art. 9 | Data Protection `complete` (SEC-STO-03) | TLS. Pin the key for endpoints you control (SEC-NET-04). | Never, unless classified, consented and declared (SEC-PRV-03) | Exclude unless required |
| **Credential** | Passwords, tokens, API secrets, keys, PINs | Keychain only (SEC-STO-01) | TLS, never in a URL | Never | Never |

Personal is one class and uses the strictest handling. If a data element
is in a GDPR Art. 9 special category (or the LGPD equivalent), write it in
the finding, so a qualified person can review the legal basis.

---

## 2. Rules

Column **Applies when** says when a rule is in force. If the condition is
false for the change, the rule does not apply.

Column **Tool** says whether gitleaks or SwiftLint can find a breach (§4).
`Y` = usually, `P` = partly, `—` = only a human or agent review finds it.

### 2.1 Storage — SEC-STO

| ID | Rule | MASVS | CWE | Tool | Applies when |
|---|---|---|---|---|---|
| SEC-STO-01 | MUST store credentials and tokens only in the Keychain. MUST NOT use `UserDefaults`, `@AppStorage`, plists, files, Core Data or SwiftData for them. | STORAGE-1 | 312, 522 | P | The app stores a credential or token |
| SEC-STO-02 | MUST give Keychain items the strictest accessibility class that works: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Use `…AfterFirstUnlockThisDeviceOnly` only when background access is required, and record why. MUST NOT enable `kSecAttrSynchronizable` without a recorded need. | STORAGE-1 | 312 | P | The app creates a Keychain item |
| SEC-STO-03 | MUST protect Personal files with Data Protection (`.completeFileProtection`, or `.completeUnlessOpen` when the file must open in the background). MUST mark them `isExcludedFromBackup` unless backup is a stated requirement. | STORAGE-1 | 311, 312 | P | Personal data is written to a file |
| SEC-STO-04 | MUST NOT write Personal or Credential data to logs, analytics, crash reports or user-visible errors. MUST NOT use `print`, `NSLog`, `dump` or `debugPrint` with such values. `Logger` interpolations use `privacy: .private` or omit the value. MUST NOT use `privacy: .public` for them. | STORAGE-2 | 532, 209 | Y | Code logs, reports errors or sends analytics near Personal or Credential data |
| SEC-STO-05 | MUST hide screens that show Personal or Credential data in the app-switcher snapshot (for example `.privacySensitive()` or a cover view on scene resign). Secret fields use secure text entry. Pasteboard writes of Personal or Credential data use `.localOnly` and an expiry, or are avoided. | STORAGE-2, PLATFORM-3 | 200 | — | A screen shows Personal or Credential data |
| SEC-STO-06 | MUST remove all user data, tokens, caches and cookies on logout and on account deletion. This includes `URLCache`, `HTTPCookieStorage` and `WKWebsiteDataStore`. | STORAGE-2 | 459 | — | The app has user accounts or stores user data |
| SEC-STO-07 | MUST NOT cache responses that hold Personal or Credential data. Use an ephemeral session configuration or `no-store`. | STORAGE-2 | 524 | — | A response holds Personal or Credential data |

### 2.2 Cryptography — SEC-CRY

| ID | Rule | MASVS | CWE | Tool | Applies when |
|---|---|---|---|---|---|
| SEC-CRY-01 | MUST use CryptoKit or Security.framework. MUST NOT write custom algorithms or protocols. | CRYPTO-1 | 327 | P | The app uses cryptography |
| SEC-CRY-02 | MUST NOT use MD5, SHA-1 (`Insecure.*`), DES, 3DES, RC4 or ECB mode for any security purpose. Use AES-GCM or ChaChaPoly, and SHA-256 or stronger. | CRYPTO-1 | 327, 326 | Y | The app hashes or encrypts anything |
| SEC-CRY-03 | MUST NOT hard-code keys, IVs, salts or secrets. Keys come from the Keychain, the Secure Enclave, or a key-derivation function. | CRYPTO-2 | 321, 798 | Y | The app handles a key or secret |
| SEC-CRY-04 | MUST use `SecRandomCopyBytes`, `SystemRandomNumberGenerator` or CryptoKit for random values with a security purpose. MUST NOT use `rand()`, `random()` or a time seed. | CRYPTO-1 | 330, 338 | Y | A random value has a security purpose |
| SEC-CRY-05 | MUST let CryptoKit generate nonces. MUST NOT reuse a nonce with the same key. SHOULD use a Secure Enclave key (`SecureEnclave.P256`) for device-bound keys when the use case fits. | CRYPTO-2 | 323 | — | The app encrypts with nonces, or uses a device-bound key |

### 2.3 Authentication — SEC-AUT

| ID | Rule | MASVS | CWE | Tool | Applies when |
|---|---|---|---|---|---|
| SEC-AUT-01 | When the app uses OAuth 2.0 or OpenID Connect: MUST use an external user agent (`ASWebAuthenticationSession`) with PKCE (RFC 8252, RFC 7636), MUST NOT use an embedded WebView for login, and MUST NOT put a client secret in the app. If the app signs in with credentials sent straight to its own backend, record an exception and SHOULD plan a move to OAuth or OIDC. | AUTH-1 | 287, 522 | — | The app signs in with OAuth or OIDC |
| SEC-AUT-02 | MUST NOT store a password on the device. MUST NOT log a password or token. MUST NOT put a token or secret in a URL or query string. | AUTH-1 | 257, 598 | P | The app handles a password or token |
| SEC-AUT-03 | MUST handle token expiry and rotation correctly: on `401`, refresh once, then ask for sign-in, and fail closed. MUST keep token refresh single-flight and actor-isolated. SHOULD request short-lived access tokens and rotating refresh tokens where the backend allows it. Extends `coding_standards.md` -> Concurrency. | AUTH-1 | 613, 362 | — | The app holds access or refresh tokens |
| SEC-AUT-04 | MUST enforce authorization on the server. MUST NOT treat a client-side flag or hidden UI as access control. | AUTH-1 | 602, 862 | — | The app calls a backend that authorises users |
| SEC-AUT-05 | When biometrics or a passcode protect data or secrets: MUST bind the protection to the Keychain item with `SecAccessControl` (`.biometryCurrentSet` or `.userPresence`). A bare `LAContext.evaluatePolicy` result is not enough, because a hooked app can fake it. When biometrics only lock the UI for convenience: SHOULD do the same. | AUTH-2 | 287 | — | Biometrics or a passcode guard data, secrets or the UI |
| SEC-AUT-06 | SHOULD require re-authentication for sensitive operations: payment, credential change, account deletion. | AUTH-3 | 306 | — | The app has a sensitive operation |

### 2.4 Network — SEC-NET

| ID | Rule | MASVS | CWE | Tool | Applies when |
|---|---|---|---|---|---|
| SEC-NET-01 | MUST use TLS for all traffic (HTTPS, WSS). MUST keep App Transport Security on. `NSAllowsArbitraryLoads`, `NSAllowsArbitraryLoadsInWebContent` and `NSExceptionAllowsInsecureHTTPLoads` are forbidden. An exception needs the domain, the reason and an expiry date, written in the plan. | NETWORK-1 | 319 | Y | The app makes any network call |
| SEC-NET-02 | MUST NOT disable or bypass certificate validation. No delegate that accepts any `serverTrust`. Custom trust checks use `SecTrustEvaluateWithError`. | NETWORK-1 | 295 | P | The app makes any network call |
| SEC-NET-03 | MUST NOT lower the TLS minimum version or weaken cipher settings below the ATS default (TLS 1.2). | NETWORK-1 | 327, 757 | P | The app makes any network call |
| SEC-NET-04 | SHOULD pin the public key (SPKI) for endpoints you control that carry Personal or Credential data. Use `NSPinnedDomains` in `Info.plist`, or a delegate. MUST pin at least two keys (current and backup) and MUST have a rotation plan, or a lone pin can lock out every user. | NETWORK-2 | 295 | P | Your own endpoint carries Personal or Credential data |
| SEC-NET-05 | MUST treat every response as untrusted: check the status and the content type, and decode with typed `Codable`. SHOULD set size limits and timeouts. | NETWORK-1, CODE-4 | 20 | — | The app consumes any response |
| SEC-NET-06 | MUST NOT open a listening socket. Outgoing sockets (`NWConnection`, WebSocket) MUST use TLS, validate the peer as in SEC-NET-02, and set timeouts and message size limits. A local listener on loopback needs an Architect exception and authentication. | NETWORK-1 | 923, 319, 306 | P | The app opens any socket |

### 2.5 Platform interaction — SEC-PLT

| ID | Rule | MASVS | CWE | Tool | Applies when |
|---|---|---|---|---|---|
| SEC-PLT-01 | MUST treat deep links and universal links as untrusted input. Prefer universal links over custom URL schemes. Validate scheme, host, path and every parameter against an allow-list. MUST NOT run a sensitive action from a link without user confirmation. | PLATFORM-1 | 939, 20 | — | The app handles a deep link or universal link |
| SEC-PLT-02 | MUST use `WKWebView` only. Limit navigation with an allow-list in `WKNavigationDelegate`. Enable JavaScript only when needed. `WKScriptMessageHandler` MUST validate the origin and the message. MUST NOT inject secrets into a page. | PLATFORM-2 | 79, 749, 346 | P | The app shows a WebView |
| SEC-PLT-03 | MUST share data through extensions, App Groups, keychain access groups, Handoff and the pasteboard at the minimum scope. Shared data follows its class in §1. | PLATFORM-1 | 200 | — | The app uses an extension, App Group, shared container, Handoff or the pasteboard |
| SEC-PLT-04 | MUST request only the entitlements and capabilities the feature needs. The plan lists each one added. `get-task-allow` MUST be false in release. | PRIVACY-1 | 250 | Y | An entitlement or capability changes |

### 2.6 Code quality — SEC-COD

| ID | Rule | MASVS | CWE | Tool | Applies when |
|---|---|---|---|---|---|
| SEC-COD-01 | MUST justify every new third-party package: maintained, and pinned in a committed `Package.resolved`. Binary targets MUST have a checksum. The plan lists new packages. | CODE-3 | 1104, 829 | P | A package is added or updated |
| SEC-COD-02 | MUST NOT ship a dependency with a known Critical or High vulnerability. Maestro runs no dependency scanner, so list the packages added or changed in the `Package.resolved` diff. Do not claim they are free of vulnerabilities. | CODE-3 | 1395 | Y | The app has any package |
| SEC-COD-03 | MUST validate and sanitise all untrusted input: user, network, file, deep link, pasteboard, push payload. Check type, length, range and format. Use parameterised queries. MUST NOT build SQL or `NSPredicate(format:)` strings from raw input. MUST resolve file paths and reject `..` escapes. | CODE-4 | 20, 89, 22, 943 | P | The app accepts untrusted input |
| SEC-COD-04 | MUST NOT use `!`, `try!` or `as!` on any path that handles external input, authentication, the Keychain or cryptography. Extends `coding_standards.md` -> Optionals. | CODE-4 | 476, 248 | Y | The code handles external input, authentication, the Keychain or cryptography |
| SEC-COD-05 | MUST NOT swallow a security error. No empty `catch`. A Keychain, crypto or authentication failure MUST fail closed (deny), never open. Extends `coding_standards.md` -> Error handling. | CODE-4 | 390, 636 | P | The code handles a security operation |
| SEC-COD-06 | SHOULD justify the minimum deployment target. MUST NOT lower it without Architect approval. | CODE-1 | — | Y | The deployment target changes |

### 2.7 Resilience — SEC-RES

Resilience controls are risk-based. Apply SEC-RES-03 only when the product
needs it (for example banking, health or DRM apps). Never use them as the
only control.

| ID | Rule | MASVS | CWE | Tool | Applies when |
|---|---|---|---|---|---|
| SEC-RES-01 | MUST NOT ship debug code, test endpoints, backdoors or verbose logging in a release build. Put them behind `#if DEBUG`. | RESILIENCE | 489, 215 | P | A release build is made |
| SEC-RES-02 | MUST NOT embed a secret that must stay secret. Everything in the binary can be extracted. A client API key only identifies the app and is not a secret. Real secrets stay on a server. | CRYPTO-2 | 798, 540 | Y | The app bundles any key, config or secret |
| SEC-RES-03 | When the risk profile requires it: platform integrity checks, anti-tamper, anti-debug and code obfuscation. | RESILIENCE-1 to 4 | — | — | The product needs it |

### 2.8 Privacy — SEC-PRV

| ID | Rule | MASVS | Regime | Tool | Applies when |
|---|---|---|---|---|---|
| SEC-PRV-01 | MUST collect only data the feature needs. Each data element has a purpose. Each permission has a purpose string (`NS…UsageDescription`) that states the real reason. SHOULD ask for a permission at the moment of use, not at launch. | PRIVACY-1 | GDPR Art. 5(1)(c); LGPD Art. 6 | P | The app collects data or asks for a permission |
| SEC-PRV-02 | MUST keep `PrivacyInfo.xcprivacy` current for the app: collected data types, tracking domains, and required-reason APIs. MUST check that each third-party SDK ships its own privacy manifest, or declare that SDK's data in the app's manifest. | PRIVACY-3 | App Store | Y | Data collection, tracking or a required-reason API changes |
| SEC-PRV-03 | MUST NOT send Personal data to analytics, advertising or crash SDKs unless it is classified, consented and declared. Tracking needs the App Tracking Transparency prompt. | PRIVACY-2, 3 | GDPR; LGPD | — | The app uses an analytics, advertising or crash SDK |
| SEC-PRV-04 | MUST give the user control: in-app account deletion when the app supports account creation (App Store Review Guideline 5.1.1(v)). Provide data export and consent withdrawal where the regime requires. | PRIVACY-4 | GDPR Art. 15–20; LGPD Art. 18 | — | The app creates accounts or collects Personal data |
| SEC-PRV-05 | MUST NOT use the advertising identifier (IDFA) except for tracking the user has consented to through App Tracking Transparency. MUST NOT fingerprint the device. Use `identifierForVendor` or an app-scoped random ID. Use the lowest location precision that works. | PRIVACY-2 | GDPR Art. 25 | — | The app uses an identifier or location |
| SEC-PRV-06 | MUST keep the App Store privacy answers equal to what the code collects. A change in collection updates the answers. | PRIVACY-3 | App Store | — | Data collection changes, and at every release |

Legal columns are pointers, not legal advice. A qualified person must
confirm GDPR, LGPD and CCPA obligations for the product.

### 2.9 Process — SEC-PRC

| ID | Rule | SSDF | CWE | Tool | Applies when |
|---|---|---|---|---|---|
| SEC-PRC-01 | MUST NOT commit secrets, real personal data, or production URLs with credentials to code, tests, fixtures, comments, screenshots or `.xcconfig` files in the repo. | PS.1 | 798, 540 | Y | Always |
| SEC-PRC-02 | If a secret is committed, treat it as leaked. **Rotate it first**, then remove it. Deleting it from history does not un-leak it. | RV.1 | 798 | — | A secret is committed |
| SEC-PRC-03 | Tests and fixtures MUST use fake data, never real tokens or real people's data. | PW.8 | 540 | Y | A test or fixture is added |

---

## 3. Severity

This is a simplified Maestro rubric. CVSS informs it but does not replace it.

| Severity | Meaning | Examples |
|---|---|---|
| **Critical** | Direct compromise of credentials or personal data, or a control fully bypassed | Committed secret. Certificate validation disabled. Token in a URL. Cleartext transport of Credential data. |
| **High** | A required control is missing or weak, and an attacker needs only common conditions | Token in `UserDefaults`. ATS exception without record. Vulnerable High dependency. Personal data in logs. |
| **Medium** | Defence-in-depth gap or a weak control with hard preconditions | No backup pin. Missing snapshot protection. Force unwrap on a non-critical path. |
| **Low** | Hardening or hygiene | Missing privacy purpose wording. Minor log noise with no sensitive data. |
| **Info** | Observation, no action required | — |

**Severity comes from exposure, not from the rule word.** A MUST breach on a
low-exposure path can be Low or Medium. Use this default, then adjust by
one level and write the reason. The matrix is a Maestro heuristic, not
a published standard.

| Data class involved | Attacker needs no special access (remote, or any app on the device) | Attacker has the unlocked device | Attacker has a jailbroken or physically held device with tools |
|---|---|---|---|
| **Credential** | Critical | High | Medium |
| **Personal** | High | Medium | Low |
| **Internal or Public** | Medium | Low | Info |

Other factors that move the level: how many users are reached, and whether
a compensating control already limits the harm.

---

## 4. What the tools check

The tools find patterns. They do not judge them. The Security Agent judges
each finding with this file.

| Tool | Finds | Rule IDs |
|---|---|---|
| gitleaks | Secrets in commits: tokens, keys, passwords | SEC-PRC-01, SEC-CRY-03, SEC-RES-02 |
| SwiftLint `sec_hardcoded_secret` | A password, token or key written in code | SEC-CRY-03, SEC-PRC-01 |
| SwiftLint `sec_userdefaults_secret` | A token or password near `UserDefaults` | SEC-STO-01 |
| SwiftLint `sec_weak_hash_or_cipher` | MD5, SHA-1, DES, 3DES, RC4 | SEC-CRY-02 |
| SwiftLint `sec_weak_random` | `rand()`, `srand()`, `drand48()` | SEC-CRY-04 |
| SwiftLint `sec_no_print_log` | `print`, `NSLog`, `dump` | SEC-STO-04 |
| SwiftLint `force_try`, `force_cast`, `force_unwrapping` | `try!`, `as!`, `!` | SEC-COD-04 |

The SwiftLint rules are in `agents/swiftlint-security.yml`.

### 4.1 Commands

Two agents run these commands: the Architect (baseline) and the Security
Agent (second scan). Run each command once in each repo the plan touches.
`[repo path]` is the absolute path of that repo.

First, check that the tools exist: `command -v gitleaks` and
`command -v swiftlint`. If a tool is missing, write `Not run — not installed`.

Time each run in milliseconds:
```bash
ms() { python3 -I -c 'import time;print(int(time.time()*1000))'; }
t0=$(ms); [command] > "$TMPDIR/maestro-sec.json" 2> "$TMPDIR/maestro-sec.err"; t1=$(ms); echo "$((t1-t0)) ms"
```

**gitleaks** — secrets in commits:
```bash
gitleaks git --log-opts="[range]" --redact --no-banner --no-color -f json -r - "[repo path]"
```
- Baseline: `[range]` is the base branch name. This scans its whole history.
- Second scan: `[range]` is `[base_branch]..[work_branch]`. This scans only
  the ticket's commits.

**SwiftLint** — security rules on tracked, non-test `.swift` files:
```bash
cd "[repo path]" && git ls-files -z -- '*.swift' ':!*Tests/*' ':!*Tests.swift' | xargs -0 swiftlint lint --config "$HOME/.maestro/agents/swiftlint-security.yml" --only-rule sec_hardcoded_secret --only-rule sec_userdefaults_secret --only-rule sec_weak_hash_or_cipher --only-rule sec_weak_random --only-rule sec_no_print_log --only-rule force_try --only-rule force_cast --only-rule force_unwrapping --reporter json --quiet --no-cache
```
- SwiftLint reads the files that are checked out. Before you run it, check
  the branch: `git -C "[repo path]" branch --show-current`. It must be the
  base branch (baseline) or the work branch (second scan). If not, write
  `Not run — not on [branch]`. Never switch branches.
- If `git ls-files` gives no file, write `Skipped — no Swift files`. Do not
  run SwiftLint without paths: it then scans the whole folder, tests too.

### 4.2 Read rules

These rules come from tests with gitleaks 8.30.1 and SwiftLint 0.65.1.

- The report is the JSON on stdout. Read stderr too.
- Do not use the exit code. gitleaks exits 1 when it finds a secret.
  SwiftLint exits 0 when it finds only warnings.
- If stderr says "is not a valid rule identifier", or the report does not
  parse, write `Not run — error: [first line of stderr]`. A rule that did
  not run must not look clean.
- Never use `gitleaks dir`. It also reads files that git does not track,
  such as `.claude/settings.local.json`.
- Always pass the repo path. A check run in the wrong repo returns 0
  findings and looks clean.
- SwiftLint gives absolute paths. Make them relative to the repo root.
- Count SwiftLint findings per rule and file. Do not compare line numbers:
  lines move.
- gitleaks hides the secret value (`--redact`). Never write the value
  anywhere. Never copy a commit author's name or email from the report.

### 4.3 Quick secret check (Developer, before each commit)

The Developer runs it after REFACTOR and before each commit:
```bash
~/.maestro/bin/maestro-secret-check "[repo path]"
```
- It checks only the staged changes, test files included.
- It uses gitleaks (known token formats) and the SwiftLint rule
  `sec_hardcoded_secret` (`password = "..."` style values). Each tool finds
  cases that the other misses.
- It prints one line: `clean`, `FOUND [n] — [rule] [file:line]`, or
  `Not run — [reason]`. It never prints a secret value.
- A parse error or a missing tool gives `Not run`, never `clean`.
- No tool finds personal data, such as a real person's email. Only a human
  or agent review finds it.

---

## 5. Limits

- These standards lower risk. They do not prove an app is secure.
- Tools find only known patterns. A lint hit is a candidate, not a proof.
- An agent review is useful but not repeatable. A human decides.
- Legal obligations need confirmation from a qualified person.
