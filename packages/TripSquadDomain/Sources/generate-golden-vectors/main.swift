// Genera `golden-vectors.json` en la raíz del paquete. Reproducible: misma semilla
// -> mismos bytes. CI regenera y hace `git diff --exit-code` para detectar deriva.
//
//   swift run generate-golden-vectors

import Foundation
import TripSquadDomain

let vectors = GoldenVectorsGen.build()
let data = try GoldenVectorsGen.json(vectors)

// La raíz del paquete es el cwd cuando se invoca `swift run` desde ahí.
let destino = URL(fileURLWithPath: "golden-vectors.json")
try data.write(to: destino)

let n = vectors.cases.count
FileHandle.standardError.write(Data("Escritos \(n) golden vectors en \(destino.path)\n".utf8))
