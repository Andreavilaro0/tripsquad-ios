# Build multi-stage del servicio Swift para Render (o cualquier contenedor Linux).
# Etapa 1: compila con la toolchain completa. Etapa 2: runtime slim.

# --- build ---
FROM swift:6.1-jammy AS build
WORKDIR /build
# Copiamos los paquetes locales que el servicio necesita por ruta relativa.
COPY packages/TripSquadDomain            ../TripSquadDomain
COPY packages/TripSquadExpenses          ../TripSquadExpenses
COPY packages/TripSquadExpensesPostgres  ../TripSquadExpensesPostgres
COPY packages/TripSquadService           ./
RUN swift build -c release --product TripSquadService

# --- runtime ---
FROM swift:6.1-jammy-slim
WORKDIR /app
COPY --from=build /build/.build/release/TripSquadService .
# Render inyecta $PORT; el servicio escucha en 0.0.0.0:$PORT.
ENV PORT=8080
EXPOSE 8080
CMD ["./TripSquadService"]
