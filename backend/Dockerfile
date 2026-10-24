FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
COPY src ./src
ENV PORT=8080
ENV TRIAL_STORE=cloudbase
EXPOSE 8080
CMD ["node", "server.js"]
