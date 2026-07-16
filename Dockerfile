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

# Nainstalujeme systémové závislosti a překladače
RUN apt-get update && apt-get install -y \
    python3 build-essential libsqlite3-dev dos2unix git \
    $( [ "$INSTALL_ODBC" = "true" ] && echo "unixodbc-dev" ) \
    && rm -rf /var/lib/apt/lists/*

# Zkopírujeme soubory balíčků pro server
COPY server/package*.json ./server/
WORKDIR /usr/src/app/FUXA/server

# Vnutíme node-snap7 i odbc přímo do závislostí hlavního serveru
RUN npm pkg set dependencies.node-snap7="^0.1.20"
RUN if [ "$INSTALL_ODBC" = "true" ]; then npm pkg set dependencies.odbc="^2.4.9"; fi

# Spustíme instalaci serveru a kompilaci nativních modulů ze zdrojového kódu
RUN npm install --no-audit --no-fund --build-from-source

# Nainstalujeme a zkompilujeme sqlite3
RUN npm install --build-from-source --sqlite=/usr/bin sqlite3

# Odstraníme vývojářské balíčky
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


# --- STAGE 3: Runner (Robustní běžové prostředí s předpřipraveným runtimem) ---
FROM node:18-bookworm
ARG INSTALL_ODBC=true
WORKDIR /usr/src/app/FUXA

# 1. Instalace potřebných systémových knihoven a kompilátorů pro jistotu
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

# 2. Zkopírování ODBC ovladačů z builderu
COPY --from=server-builder /usr/lib/odbc/ /usr/lib/odbc/
COPY --from=server-builder /opt/microsoft/ /opt/microsoft/

# 3. Zkopírování serveru a klientské části
COPY --from=server-builder /usr/src/app/FUXA/server ./server
COPY --from=client-builder /usr/src/app/client/dist ./client/dist
COPY --from=server-builder /usr/src/app/FUXA/odbc ./odbc
RUN if [ "$INSTALL_ODBC" = "true" ]; then cp odbc/odbcinst.ini /etc/odbcinst.ini; fi
COPY node-red/ ./node-red/

# --- ROZHODUJÍCÍ BYPASS PRO S7 A ODBC ---
# Vytvoříme runtime složku, kam FUXA sahá, a nainstalujeme a zkompilujeme tam moduly předem
WORKDIR /usr/src/app/FUXA/server/_pkg/runtime
RUN npm init -y \
    && npm pkg set dependencies.node-snap7="^0.1.20" \
    && if [ "$INSTALL_ODBC" = "true" ]; then npm pkg set dependencies.odbc="^2.4.9"; fi \
    && npm install --build-from-source

# Návrat do hlavního adresáře serveru
WORKDIR /usr/src/app/FUXA/server

ENV NODE_ENV=production
EXPOSE 1881
CMD [ "node", "main.js" ]
