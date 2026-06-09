FROM mcr.microsoft.com/playwright:v1.60.0-jammy

WORKDIR /worker

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY server.js ./

USER pwuser

CMD ["node", "server.js"]
