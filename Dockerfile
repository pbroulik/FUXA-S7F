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

# Nainstalujeme systémové závislosti a překladače (zde Python 3 je a funguje)
RUN apt-get update && apt-get install -y \
    python3 build-essential libsqlite3-dev dos2unix git \
    $( [ "$INSTALL_ODBC" = "true" ] && echo "unixodbc-dev" ) \
    && rm -rf /var/lib/apt/lists/*

# Zkopírujeme soubory balíčků pro server
COPY server/package*.json ./server/
WORKDIR /usr/src/app/FUXA/server

# Vnutíme node-snap7 přímo do závislostí hlavního serveru, aby se zkompiloval hned teď
RUN npm pkg set dependencies.node-snap7="^0.1.20"

# Spustíme instalaci serveru a kompilaci nativních modulů ze zdrojového kódu
RUN npm install --no-audit --no-fund --build-from-source

# Nainstalujeme a zkompilujeme sqlite3
RUN npm install --build-from-source --sqlite=/usr/bin sqlite3

# Odstraníme vývojářské balíčky, abychom ušetřili místo
RUN npm prune --production

# Příprava ODBC ovladačů (pokud jsou aktivní)
WORKDIR /usr/src/app/FUXA/odbc
COPY odbc/ ./
RUN if [ "$INSTALL_ODBC" = "true" ]; then \
    dos2unix install_odbc_drivers.sh && chmod +x install_odbc_drivers.sh && ./install_odbc_drivers.sh; \
    fi \
    && mkdir -p /usr/lib/odbc /opt/microsoft

# Zkopírujeme zdrojové kódy serveru a sestavíme ho
WORKDIR /usr/src/app/FUXA/server
COPY server/ ./
RUN rm -rf test
RUN npm run build

# --- STAGE 3: Runner (Čisté a lehké produkční prostředí) ---
FROM node:18-bookworm-slim
ARG INSTALL_ODBC=true
WORKDIR /usr/src/app/FUXA

# Nainstalujeme pouze nutné běhové knihovny, žádný kompilátor ani Python
RUN apt-get update \
    && apt-get install -y \
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

# Zkopírujeme kompletní hotový server (včetně předpřipraveného a zkompilovaného node-snap7)
COPY --from=server-builder /usr/src/app/FUXA/server ./server

# Zkopírujeme klientskou část (Angular web)
COPY --from=client-builder /usr/src/app/client/dist ./client/dist

# Zkopírujeme konfiguraci ODBC (pokud je aktivní)
COPY --from=server-builder /usr/src/app/FUXA/odbc ./odbc
RUN if [ "$INSTALL_ODBC" = "true" ]; then cp odbc/odbcinst.ini /etc/odbcinst.ini; fi

# Zkopírujeme statické soubory aplikace
COPY node-red/ ./node-red/

# Nastavení pracovního adresáře pro spuštění
WORKDIR /usr/src/app/FUXA/server

ENV NODE_ENV=production
EXPOSE 1881
CMD [ "node", "main.js" ]
