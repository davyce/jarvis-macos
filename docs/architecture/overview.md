# Architecture Jarvis

```text
apps/jarvis-macos  Interface SwiftUI native, navigation et integration systeme
services/core      Orchestration et Project State
services/observer  Observation locale des ressources autorisees
services/voice     Pipeline vocal et interruption
services/bridge    Actions controlees via Limule Bridge
packages/*         Contrats versionnes entre les composants
database/*         Etat local et migrations SQLite
```

## Responsabilites

```text
Limule  -> raisonne a partir d'un contexte structure
Jarvis  -> rassemble ce contexte et presente les resultats
Bridge  -> execute les actions autorisees et retourne une preuve de resultat
```

## Projets initiaux

1. Limule
2. ZOLA
3. KOMPTA

Limule est le premier projet de validation. ZOLA et KOMPTA restent visibles
dans le registre des le debut afin de valider que Jarvis pense en portefeuille
de projets, sans etendre prematurement ses capacites d'observation.
