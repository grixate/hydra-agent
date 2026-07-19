FROM mcr.microsoft.com/playwright:v1.61.0-noble

ENV NODE_ENV=production \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

WORKDIR /worker

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts \
  && npm cache clean --force

COPY server.js smoke.js server.test.js accessibility-audit.js ./
RUN npm run check && HYDRA_BROWSER_INTEGRATION_TEST=1 npm test
RUN rm -rf /usr/lib/node_modules/npm \
  && rm -f /usr/bin/npm /usr/bin/npx \
  && rm -f server.test.js accessibility-audit.js

USER pwuser

EXPOSE 4100

HEALTHCHECK --interval=10s --timeout=8s --start-period=30s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:4100/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
