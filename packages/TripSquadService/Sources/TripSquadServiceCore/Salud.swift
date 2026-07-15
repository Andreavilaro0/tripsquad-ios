// GET /health — verifica el servicio y su dependencia Postgres (ADR-0009 §5,
// Health Endpoint Monitoring). Sin auth (guía §11).

import Hummingbird

func montarSalud(_ router: Router<BasicRequestContext>, _ deps: Dependencias) {
    router.get("health") { _, _ -> Response in
        let bdOk = await deps.pingBD()
        let cuerpo = #"{"status":"\#(bdOk ? "ok" : "degraded")","db":\#(bdOk)}"#
        return Response(
            status: bdOk ? .ok : .serviceUnavailable,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: cuerpo))
        )
    }
}
