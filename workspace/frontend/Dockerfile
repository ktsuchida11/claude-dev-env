FROM node:20-slim

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --fund=false --update-notifier=false

# ソースはbind mountで上書きされるため、COPYは本番用
COPY . .

CMD ["npm", "run", "dev"]
