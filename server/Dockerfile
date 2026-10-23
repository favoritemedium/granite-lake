FROM node:22.23.4-slim AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install

FROM deps AS build
WORKDIR /app
COPY tsconfig.json ./
COPY src ./src
COPY tests ./tests
RUN npm run build

FROM node:22.23.4-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY --from=build /app/dist ./dist
COPY src/db/migrations ./dist/src/db/migrations
EXPOSE 8080
CMD ["node", "dist/src/server.js"]
