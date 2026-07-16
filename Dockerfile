# --- STAGE 1: Angular Client Builder ---
FROM node:18-bookworm AS client-builder
WORKDIR /usr/src/app/client
COPY client/package*.json ./
RUN npm install --no-audit --no-fund
COPY client/ ./
RUN npm run build -- --configuration production

# --- STAGE 2: Server Build & Install ---
FROM node:18-bookworm AS server-builder
WORKDIR /usr/src/app/FUXA

# Nainstalujeme kompilátory a HLAVNĚ libsnap7-dev přímo z repozitáře Debianu
RUN apt-get update && apt-get install -y \
    python3 \
    build-essential \
    libsnap7-dev \
    libsqlite3-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

# Příprava složek
COPY server/package*.json ./server/
WORKDIR /usr/src/app/FUXA/server

# Vnutíme node-snap7 do závislostí před instalací
RUN npm pkg set dependencies.node-snap7="^0.1.20"

# Nainstalujeme a zkompilujeme vše (včetně node-snap7, který se hladce propojí s libsnap7)
RUN npm install --no-audit --no-fund --build-from-source
RUN npm install --build-from-source --sqlite=/usr/bin sqlite3
RUN npm prune --production

# Zkopírujeme kód a sestavíme server
COPY server/ ./
RUN rm -rf test
RUN npm run build


# --- STAGE 3: Běhové prostředí ---
FROM node:18-bookworm-slim
WORKDIR /usr/src/app/FUXA

# Pro běh node-snap7 potřebujeme v systému pouze runtime knihovnu libsnap7 a sqlite
RUN apt-get update && apt-get install -y \
    libsnap7-1 \
    sqlite3 \
    libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

# Zkopírujeme hotový, zkompilovaný server z předchozího kroku
COPY --from=server-builder /usr/src/app/FUXA/server ./server
COPY --from=client-builder /usr/src/app/client/dist ./client/dist
COPY node-red/ ./node-red/

# --- KLÍČOVÝ KROK: Vytvoříme runtime prostředí pro FUXA ---
# FUXA vyžaduje, aby v '_pkg/runtime' byl package.json, kde je node-snap7 deklarován,
# a v 'node_modules' musí fyzicky existovat funkční zkompilovaný modul.
WORKDIR /usr/src/app/FUXA/server/_pkg/runtime
RUN echo '{"dependencies":{"node-snap7":"^0.1.20"}}' > package.json \
    && mkdir -p node_modules \
    && cp -r /usr/src/app/FUXA/server/node_modules/node-snap7 node_modules/

# Zpět do hlavního adresáře serveru
WORKDIR /usr/src/app/FUXA/server

ENV NODE_ENV=production
EXPOSE 1881
CMD [ "node", "main.js" ]
