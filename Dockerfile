FROM node:22-slim
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY servidor.js ./
ENV PORT=8080
EXPOSE 8080
CMD ["node", "servidor.js"]
