#!/usr/bin/env bash
# Démarre les émulateurs Firebase (Firestore + Auth), lance les tests
# d'intégration Firebase de BDDouilleur, puis arrête les émulateurs.
# Prérequis : firebase-tools (npm) et Java 11+.
set -euo pipefail
cd "$(dirname "$0")/.."
FIREBASE="${FIREBASE_BIN:-firebase}"
if [ -z "${JAVA_HOME:-}" ] && [ -d /opt/android-studio/jbr ]; then export PATH=/opt/android-studio/jbr/bin:$PATH; fi
cd tool/firebase_emulator
"$FIREBASE" emulators:exec --only firestore,auth --project demo-bddouilleur \
  "cd ../.. && flutter test test_emulator/ $*"
