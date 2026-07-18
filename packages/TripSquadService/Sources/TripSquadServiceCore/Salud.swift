// GET /health — verifica el servicio y su dependencia Postgres (ADR-0009 §5,
// Health Endpoint Monitoring). Sin auth (guía §11).

import Hummingbird

func montarSalud(_ router: Router<BasicRequestContext>, _ deps: Dependencias) {
    // Liveness para el health check de Render: SIEMPRE 200 si el proceso está vivo.
    // No comprueba la BD — si lo hiciera, un fallo de Supabase tumbaría el deploy.
    router.get("live") { _, _ -> Response in
        Response(status: .ok, headers: [.contentType: "application/json"],
                 body: .init(byteBuffer: .init(string: #"{"status":"alive"}"#)))
    }

    // Health con dependencia (ADR-0009 §5): 503 si Postgres no responde. Para
    // monitorización, NO para el health check de Render.
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
