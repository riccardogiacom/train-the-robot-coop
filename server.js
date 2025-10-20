const express = require("express");
const http = require("http");
const { Server } = require("socket.io");

const app = express();
const server = http.createServer(app);
const io = new Server(server);

let dataset = [];
let model = null;

app.use(express.static("public"));

io.on("connection", (socket) => {
  console.log("🟢 Nuovo giocatore collegato:", socket.id);

  socket.on("setName", (name) => {
    socket.data.username = name;
    console.log(`👤 ${name} si è unito`);
    socket.emit("status", { datasetSize: dataset.length });
    io.emit("userJoined", { name, totalPlayers: countPlayers() });
  });

  socket.on("trainExample", (data) => {
    const player = socket.data.username || "Anonimo";
    dataset.push({ ...data, player });
    console.log(`📚 Nuovo esempio da ${player}: ${JSON.stringify(data)} (${dataset.length} totali)`);

    // Aggiorna il modello dinamicamente
    model = trainModel(dataset);

    io.emit("datasetUpdate", {
      size: dataset.length,
      accuracy: model.accuracy,
      fairness: model.fairnessGap
    });
  });

  socket.on("predict", (data) => {
    if (!model) {
      socket.emit("predictionResult", { error: "Il modello non è ancora stato addestrato!" });
      return;
    }
    const result = model.predict(data);
    socket.emit("predictionResult", { ...data, prediction: result });
  });

  socket.on("resetModel", () => {
    console.log(`🔄 Reset richiesto da ${socket.data.username || "un utente"}`);
    dataset = [];
    model = null;
    io.emit("resetDone", { message: "🔄 Il robot è stato resettato da un partecipante!" });
  });

  socket.on("disconnect", () => {
    console.log("🔴 Giocatore disconnesso:", socket.data.username || socket.id);
  });
});

function trainModel(data) {
  if (data.length === 0) return null;

  const positives = data.filter(d => d.label);
  if (positives.length === 0) {
    return { predict: () => false, accuracy: 0, fairnessGap: 0 };
  }

  // Medie e statistiche base
  const avgEta = positives.reduce((a,b)=>a+b.eta,0)/positives.length;
  const avgReddito = positives.reduce((a,b)=>a+b.reddito,0)/positives.length;
  const disabRate = positives.filter(d=>d.disabilita).length / positives.length;

  // Predittore semplificato
  const predictor = (p) => (p.eta > avgEta - 5 || p.reddito < avgReddito || p.disabilita);

  // Accuratezza
  let correct = 0;
  for (const d of data) {
    const pred = predictor(d);
    if (pred === d.label) correct++;
  }
  const accuracy = correct / data.length;

  // Fairness gap (es. tra disabili e non disabili)
  const preds = data.map(d => ({ ...d, pred: predictor(d) }));
  const disabTrue = preds.filter(d => d.disabilita);
  const disabFalse = preds.filter(d => !d.disabilita);
  const rateTrue = disabTrue.length ? disabTrue.filter(d=>d.pred).length / disabTrue.length : 0;
  const rateFalse = disabFalse.length ? disabFalse.filter(d=>d.pred).length / disabFalse.length : 0;
  const fairnessGap = Math.abs(rateTrue - rateFalse);

  console.log(`✅ Modello aggiornato con ${data.length} esempi (accuracy: ${accuracy.toFixed(2)}, fairnessGap: ${fairnessGap.toFixed(2)})`);

  return {
    avgEta, avgReddito, disabRate, accuracy, fairnessGap,
    predict: predictor
  };
}

function countPlayers() {
  return [...io.sockets.sockets.values()].filter(s => s.data.username).length;
}

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`✅ Server running on port ${PORT}`));
