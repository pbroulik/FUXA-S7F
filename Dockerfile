# --- STAGE 1: Angular Client Builder ---
FROM node:18-bookworm AS client-builder
WORKDIR /usr/src/app/client
COPY client/package*.json ./
RUN npm install --no-audit --no-fund
COPY client/ ./
RUN npm run build -- --configuration production

# --- STAGE 2: Server & Native Dependencies Builder ---
FROM node:18-bookworm AS server-builder
# Define build arguments with defaults
ARG NODE_SNAP=true
ARG INSTALL_ODBC=true

WORKDIR /usr/src/app/FUXA

# Base build tools
RUN apt-get update && apt-get install -y \
    python3 build-essential libsqlite3-dev dos2unix git \
    $( [ "$INSTALL_ODBC" = "true" ] && echo "unixodbc-dev" ) \
    && rm -rf /var/lib/apt/lists/*

# Install Server dependencies
COPY server/package*.json ./server/
WORKDIR /usr/src/app/FUXA/server
RUN npm install --no-audit --no-fund

# Optional Snap7 installation
RUN if [ "$NODE_SNAP" = "true" ]; then \
    npm install node-snap7 --no-audit --no-fund --build-from-source; \
    fi

# Force rebuild of SQLite for the container
RUN npm install --build-from-source --sqlite=/usr/bin sqlite3

# Vyčištění pouze nepotřebných devDependencies
RUN npm prune --production

# Optional ODBC driver preparation
WORKDIR /usr/src/app/FUXA/odbc
COPY odbc/ ./
RUN if [ "$INSTALL_ODBC" = "true" ]; then \
    dos2unix install_odbc_drivers.sh && chmod +x install_odbc_drivers.sh && ./install_odbc_drivers.sh; \
    fi \
    && mkdir -p /usr/lib/odbc /opt/microsoft

# 3. Copy server source, build, then cleanup
WORKDIR /usr/src/app/FUXA/server
COPY server/ ./
RUN rm -rf test
RUN npm run build

# --- STAGE 3: Runner ---
FROM node:18-bookworm-slim
ARG INSTALL_ODBC=true
WORKDIR /usr/src/app/FUXA

# 1. Globální nastavení Pythonu pro npm a node-gyp, aby ho viděly i procesy na pozadí
ENV PYTHON=/usr/bin/python3
RUN npm config set python /usr/bin/python3 --global

# 2. Instalace runtime knihoven, Pythonu a kompletních buildovacích nástrojů do finálního běžícího kontejneru
RUN apt-get update \
    && apt-get install -y \
        sqlite3 libsqlite3-0 \
        python3 python3-pip build-essential g++ make \
        $( [ "$INSTALL_ODBC" = "true" ] && echo "unixodbc odbc-mariadb odbc-postgresql libsqliteodbc tdsodbc unixodbc-dev" ) \
    && if [ "$INSTALL_ODBC" = "true" ]; then \
        mkdir -p /usr/lib/odbc && \
        find /usr/lib -path '*/odbc/*.so' -exec cp {} /usr/lib/odbc/ \; ; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# Copy MySQL and MSSQL ODBC drivers from builder
COPY --from=server-builder /usr/lib/odbc/ /usr/lib/odbc/
COPY --from=server-builder /opt/microsoft/ /opt/microsoft/

# Copy Server
COPY --from=server-builder /usr/src/app/FUXA/server ./server

# Copy Client
COPY --from=client-builder /usr/src/app/client/dist ./client/dist

# Conditional ODBC Config
COPY --from=server-builder /usr/src/app/FUXA/odbc ./odbc
RUN if [ "$INSTALL_ODBC" = "true" ]; then cp odbc/odbcinst.ini /etc/odbcinst.ini; fi

# Copy static app files
COPY node-red/ ./node-red/

# Final cleanup
WORKDIR /usr/src/app/FUXA/server

ENV NODE_ENV=production
EXPOSE 1881
CMD [ "node", "main.js" ]
