# --- STAGE 1: Angular Client Builder ---
FROM node:18-bookworm AS client-builder
WORKDIR /usr/src/app/client
COPY client/package*.json ./
RUN npm install --no-audit --no-fund
COPY client/ ./
RUN npm run build -- --configuration production

# --- STAGE 2: Server & Native Dependencies Builder ---
FROM node:18-bookworm AS server-builder
ARG INSTALL_ODBC=true

WORKDIR /usr/src/app/FUXA

RUN apt-get update && apt-get install -y \
    python3 build-essential libsqlite3-dev dos2unix git \
    $( [ "$INSTALL_ODBC" = "true" ] && echo "unixodbc-dev" ) \
    && rm -rf /var/lib/apt/lists/*

COPY server/package*.json ./server/
WORKDIR /usr/src/app/FUXA/server

RUN npm pkg set dependencies.node-snap7="^0.1.20"
RUN if [ "$INSTALL_ODBC" = "true" ]; then npm pkg set dependencies.odbc="^2.4.9"; fi
RUN npm install --no-audit --no-fund --build-from-source
RUN npm install --build-from-source --sqlite=/usr/bin sqlite3
RUN npm prune --production

WORKDIR /usr/src/app/FUXA/odbc
COPY odbc/ ./
RUN if [ "$INSTALL_ODBC" = "true" ]; then \
    dos2unix install_odbc_drivers.sh && chmod +x install_odbc_drivers.sh && ./install_odbc_drivers.sh; \
    fi \
    && mkdir -p /usr/lib/odbc /opt/microsoft

WORKDIR /usr/src/app/FUXA/server
COPY server/ ./
RUN rm -rf test
RUN npm run build

# --- STAGE 3: Runner (Robustní běhové prostředí s podporou kompilace) ---
# Použijeme plný obraz, ne slim, aby měl systém k dispozici build nástroje pro runtime instalace
FROM node:18-bookworm
ARG INSTALL_ODBC=true
WORKDIR /usr/src/app/FUXA

# Nainstalujeme Python, překladače a knihovny i do finálního kontejneru
RUN apt-get update \
    && apt-get install -y \
        python3 build-essential g++ make \
        sqlite3 libsqlite3-0 \
        $( [ "$INSTALL_ODBC" = "true" ] && echo "unixodbc odbc-mariadb odbc-postgresql libsqliteodbc tdsodbc unixodbc-dev" ) \
    && if [ "$INSTALL_ODBC" = "true" ]; then \
        mkdir -p /usr/lib/odbc && \
        find /usr/lib -path '*/odbc/*.so' -exec cp {} /usr/lib/odbc/ \; ; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# Zkopírujeme ODBC ovladače z builderu
COPY --from=server-builder /usr/lib/odbc/ /usr/lib/odbc/
COPY --from=server-builder /opt/microsoft/ /opt/microsoft/

# Zkopírujeme kompletní hotový server
COPY --from=server-builder /usr/src/app/FUXA/server ./server

# Zkopírujeme klientskou část (Angular web)
COPY --from=client-builder /usr/src/app/client/dist ./client/dist

# Zkopírujeme konfiguraci ODBC (pokud je aktivní)
COPY --from=server-builder /usr/src/app/FUXA/odbc ./odbc
RUN if [ "$INSTALL_ODBC" = "true" ]; then cp odbc/odbcinst.ini /etc/odbcinst.ini; fi

# Zkopírujeme statické soubory aplikace
COPY node-red/ ./node-red/

WORKDIR /usr/src/app/FUXA/server

ENV NODE_ENV=production
EXPOSE 1881
CMD [ "node", "main.js" ]
