#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "=== 📡 INITIALIZING NASA EMIT COCKPIT ENVIRONMENT ==="

# 1. Update system packages and install Node.js + SQLite build tools
apt update && apt upgrade -y
apt install -y nodejs python make g++ sqlite

# 2. Setup project infrastructure
mkdir -p ~/hud/public
cd ~/hud

echo "=== 📦 INSTALLING DEPENDENCIES ==="
# Initialize node project and install required packages
npm init -y
npm install express ws sqlite3

# 3. Create Background Worker Thread (gis_worker.js)
echo "=== 🧠 WRITING BACKGROUND WORKER ==="
cat << 'EOF' > gis_worker.js
const { parentPort } = require('worker_threads');

parentPort.on('message', (msg) => {
    if (msg.type === 'GEOJSON_COMPILE') {
        try {
            const lines = msg.data.trim().split('\n').filter(Boolean);
            const features = lines.map(line => {
                const parts = line.split('|');
                if (parts.length < 6) return null;
                
                const [timestamp, alpha, beta, mineral, confidence, gpsStr] = parts;
                const [lat, lon] = gpsStr.split(',').map(Number);
                
                return {
                    type: "Feature",
                    geometry: { type: "Point", coordinates: [lon, lat] },
                    properties: {
                        timestamp,
                        azimuth: parseFloat(alpha),
                        elevation: parseFloat(beta),
                        mineral,
                        confidence: parseFloat(confidence)
                    }
                };
            }).filter(Boolean);

            const geojson = JSON.stringify({ type: "FeatureCollection", features });
            parentPort.postMessage({ status: 'SUCCESS', result: geojson });
        } catch (err) {
            parentPort.postMessage({ status: 'ERROR', error: err.message });
        }
    }
});
EOF

# 4. Create Backend Engine + SQL Database Connection (index.cjs)
echo "=== 🛠️ WRITING BACKEND ENGINE ==="
cat << 'EOF' > index.cjs
const express = require('express');
const http = require('http');
const path = require('path');
const WebSocket = require('ws');
const fs = require('fs');
const { Worker } = require('worker_threads');
const sqlite3 = require('sqlite3').verbose();

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });
const PORT = 8084;

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const streamTarget = path.join(__dirname, 'emit_stream.log');
const dbTarget = path.join(__dirname, 'emit_telemetry.db');

let calibrationBuffer = [];
let BUFFER_LIMIT = 5;

const db = new sqlite3.Database(dbTarget, (err) => {
    if (!err) {
        db.run(`CREATE TABLE IF NOT EXISTS spatial_telemetry (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT,
            azimuth_alpha REAL,
            elevation_beta REAL,
            gamma_tilt REAL,
            mineral_name TEXT,
            confidence_pct REAL,
            latitude REAL,
            longitude REAL
        )`);
    }
});

const SPECTRAL_REGISTRY = {
    gold: { name: "Gold (Native)", color: "#ffcc00", formula: "Au", vector: [0.10, 0.15, 0.40, 0.85, 0.95] },
    hematite: { name: "Hematite", color: "#ff2a2a", formula: "Fe2O3", vector: [0.08, 0.12, 0.48, 0.32, 0.10] },
    goethite: { name: "Goethite", color: "#d4a373", formula: "FeO(OH)", vector: [0.05, 0.25, 0.35, 0.25, 0.12] },
    kaolinite: { name: "Kaolinite", color: "#00b4d8", formula: "Al2Si2O5(OH)4", vector: [0.68, 0.55, 0.38, 0.08, 0.32] },
    gypsum: { name: "Gypsum", color: "#e9ecef", formula: "CaSO4·2H2O", vector: [0.72, 0.64, 0.28, 0.48, 0.05] }
};

function filterSensors(rawAlpha, rawBeta, rawGamma) {
    calibrationBuffer.push({ alpha: rawAlpha, beta: rawBeta, gamma: rawGamma });
    while (calibrationBuffer.length > BUFFER_LIMIT) calibrationBuffer.shift();
    
    const sum = calibrationBuffer.reduce((acc, val) => {
        acc.alpha += val.alpha; acc.beta += val.beta; acc.gamma += val.gamma;
        return acc;
    }, { alpha: 0, beta: 0, gamma: 0 });

    return {
        alpha: sum.alpha / calibrationBuffer.length,
        beta: sum.beta / calibrationBuffer.length,
        gamma: sum.gamma / calibrationBuffer.length
    };
}

function processTelemetryPayload(rawAlpha, rawBeta, rawGamma) {
    const { alpha, beta, gamma } = filterSensors(rawAlpha, rawBeta, rawGamma);
    let match = null, confidence = 0;

    if (alpha > 15 && alpha < 40 && beta > 40 && beta < 75) {
        match = SPECTRAL_REGISTRY.gold;
        confidence = Math.sin((alpha - 15) / 25 * Math.PI) * 100;
    } else if (alpha > 45 && alpha < 135 && beta > 5 && beta < 60) {
        match = SPECTRAL_REGISTRY.hematite;
        confidence = Math.sin((alpha - 45) / 90 * Math.PI) * 100;
    } else if (alpha > 160 && alpha < 250 && beta > -30 && beta < 20) {
        match = SPECTRAL_REGISTRY.kaolinite;
        confidence = Math.sin((alpha - 160) / 90 * Math.PI) * 100;
    } else if (alpha > 260 && alpha < 310 && beta > 10 && beta < 50) {
        match = SPECTRAL_REGISTRY.goethite;
        confidence = Math.sin((alpha - 260) / 50 * Math.PI) * 100;
    } else if (alpha > 315 && alpha < 360 && beta > -15 && beta < 15) {
        match = SPECTRAL_REGISTRY.gypsum;
        confidence = Math.sin((alpha - 315) / 45 * Math.PI) * 100;
    }

    const gps = {
        lat: parseFloat((34.0522 + (alpha * 0.0001)).toFixed(6)),
        lon: parseFloat((-118.2437 + (beta * 0.0001)).toFixed(6))
    };
    const timeIso = new Date().toISOString();

    fs.appendFile(streamTarget, `${timeIso}|${alpha.toFixed(2)}|${beta.toFixed(2)}|${match ? match.name : 'Void'}|${confidence.toFixed(1)}|${gps.lat},${gps.lon}\n`, () => {});
    
    db.run(`INSERT INTO spatial_telemetry (timestamp, azimuth_alpha, elevation_beta, gamma_tilt, mineral_name, confidence_pct, latitude, longitude) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        [timeIso, alpha, beta, gamma, match ? match.name : 'Void', confidence, gps.lat, gps.lon]
    );

    const broadcastPayload = JSON.stringify({ alpha, beta, gamma, match: match ? { name: match.name, color: match.color, formula: match.formula, confidence: confidence.toFixed(1) } : null, gps });
    wss.clients.forEach(c => { if (c.readyState === WebSocket.OPEN) c.send(broadcastPayload); });

    return { alpha, beta, gamma, match, gps, confidence };
}

// REST Routes
app.get('/api/health', (req, res) => {
    res.json({ status: "online", uptime: process.uptime(), buffer_depth: calibrationBuffer.length, window_limit: BUFFER_LIMIT, sql_mirror_active: true });
});

app.get('/api/export/sql', (req, res) => {
    db.all(`SELECT * FROM spatial_telemetry ORDER BY id DESC LIMIT 500`, [], (err, rows) => {
        if (err) return res.status(500).json({ error: "Database fault." });
        res.status(200).json(rows);
    });
});

app.post('/api/telemetry/ingest', (req, res) => {
    const { alpha, beta, gamma } = req.body;
    if (alpha === undefined || beta === undefined) return res.status(400).json({ error: "Missing parameters." });
    const dataSummary = processTelemetryPayload(parseFloat(alpha), parseFloat(beta), parseFloat(gamma || 0));
    res.status(200).json({ status: "processed", match_detected: dataSummary.match ? dataSummary.match.name : "Void" });
});

app.get('/api/export/csv', (req, res) => {
    if (!fs.existsSync(streamTarget)) return res.status(404).send("No data.");
    fs.readFile(streamTarget, 'utf8', (err, data) => {
        if (err) return res.status(500).send("Read fault.");
        const lines = data.trim().split('\n').filter(Boolean);
        let csv = "Timestamp,Azimuth_Alpha,Elevation_Beta,Identified_Mineral,Confidence_Pct,Latitude,Longitude\n";
        lines.forEach(line => {
            const parts = line.split('|');
            if (parts.length >= 6) csv += `${parts[0]},${parts[1]},${parts[2]},${parts[3]},${parts[4]},${parts[5].replace(',', ';')}\n`;
        });
        res.setHeader('Content-Type', 'text/csv');
        res.setHeader('Content-Disposition', 'attachment; filename=emit_export.csv');
        res.status(200).send(csv);
    });
});

app.get('/api/export/geojson', (req, res) => {
    if (!fs.existsSync(streamTarget)) return res.status(404).json({ error: "No data." });
    fs.readFile(streamTarget, 'utf8', (err, logData) => {
        const worker = new Worker(path.join(__dirname, 'gis_worker.js'));
        worker.postMessage({ type: 'GEOJSON_COMPILE', data: logData });
        worker.on('message', (msg) => {
            if (msg.status === 'SUCCESS') {
                res.setHeader('Content-Type', 'application/geo+json');
                res.setHeader('Content-Disposition', 'attachment; filename=emit_vectors.geojson');
                res.status(200).send(msg.result);
            } else res.status(500).json({ error: "Worker fail." });
            worker.terminate();
        });
    });
});

wss.on('connection', (ws) => {
    ws.on('message', (payload) => {
        try {
            const raw = JSON.parse(payload);
            processTelemetryPayload(raw.alpha || 0, raw.beta || 0, raw.gamma || 0);
        } catch (e) {}
    });
});

server.listen(PORT, () => console.log(`[AVIONICS ENGINE RUNNING ON PORT ${PORT}]`));
EOF

# 5. Create Avionics HUD Front-End (public/index.html)
echo "=== 🎨 WRITING FRONTEND HUD ==="
cat << 'EOF' > public/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NASA EMIT Cockpit Avionics</title>
    <style>
        body { margin: 0; background: #010103; color: #00ffaa; font-family: 'Courier New', monospace; overflow: hidden; user-select: none; }
        #targeting-grid { position: absolute; top: 0; left: 0; width: 100vw; height: 100vh; pointer-events: none; border: 2px solid rgba(0, 255, 170, 0.15); box-sizing: border-box; }
        #reticle { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); width: 80px; height: 80px; border: 2px dashed rgba(0,255,170,0.4); border-radius: 50%; }
        #reticle::after { content: ''; position: absolute; top: 50%; left: 50%; width: 6px; height: 6px; background: #00ffaa; border-radius: 50%; transform: translate(-50%, -50%); }
        
        /* --- ADD-ON 17: Structural Layout & Tab Navigation --- */
        .panel { position: absolute; background: rgba(1, 4, 8, 0.95); border: 1px solid #00ffaa; padding: 14px; border-radius: 2px; box-shadow: 0 0 30px rgba(0,255,170,0.25); z-index: 10; }
        #panel-left { top: 70px; left: 20px; width: 320px; }
        #panel-right { top: 70px; right: 20px; width: 300px; }
        #panel-bottom { bottom: 20px; left: 20px; width: 360px; }
        #panel-radar { bottom: 20px; right: 20px; width: 300px; height: 260px; }
        
        .tab-bar { position: absolute; top: 15px; left: 20px; display: flex; gap: 10px; z-index: 20; }
        .tab-btn { background: #010408; border: 1px solid rgba(0,255,170,0.4); color: rgba(0,255,170,0.6); padding: 6px 16px; cursor: pointer; font-family: monospace; font-weight: bold; }
        .tab-btn.active { border-color: #00ffaa; color: #00ffaa; box-shadow: 0 0 10px rgba(0,255,170,0.2); }
        .tab-content { display: none; }
        .tab-content.active { display: block; }

        button { background: #010408; border: 1px solid #00ffaa; color: #00ffaa; padding: 6px 12px; font-family: monospace; cursor: pointer; margin-right: 5px; margin-top: 5px; }
        button:hover { background: #00ffaa; color: #010408; }
        hr { border: 0; border-top: 1px solid rgba(0, 255, 170, 0.3); margin: 10px 0; }
        .meta-stat { font-size: 0.85em; color: #00aa77; }
        
        /* --- ADD-ON 18: SVG Blip Radar styling --- */
        #radar-display { width: 100%; height: 200px; background: #02080c; border: 1px solid rgba(0,255,170,0.2); }
        .radar-sweep { transform-origin: 150px 100px; animation: sweep 4s linear infinite; stroke: rgba(0,255,170,0.15); }
        @keyframes sweep { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div id="targeting-grid"></div>
    <div id="reticle"></div>

    <div class="tab-bar">
        <button class="tab-btn active" onclick="switchTab('avionics')">AVIONICS HUD</button>
        <button class="tab-btn" onclick="switchTab('diagnostics')">DIAGNOSTICS & SYSTEM</button>
    </div>

    <div id="avionics-tab" class="tab-content active">
        <div id="panel-left" class="panel">
            <h3>📡 TELEMETRY CORE</h3>
            <hr/>
            <p>AZIMUTH (α): <span id="val-alpha">0.00</span>°</p>
            <p>ELEVATION (β): <span id="val-beta">0.00</span>°</p>
            <p>TILT (γ): <span id="val-gamma">0.00</span>°</p>
            <div class="meta-stat" id="gps-coords">GPS: Projecting coordinate matrix...</div>
        </div>

        <div id="panel-right" class="panel">
            <h3>🔬 SPECTRAL MATCH</h3>
            <hr/>
            <p>MINERAL: <span id="m-name" style="font-weight:bold;">Void</span></p>
            <p>FORMULA: <span id="m-form">-</span></p>
            <p>CONFIDENCE: <span id="m-conf">0.0</span>%</p>
            <div class="meta-stat" id="target-status">STATUS: SCANNING TRACK</div>
        </div>

        <div id="panel-radar" class="panel">
            <h3>🧭 SPATIAL DISTRO RADAR</h3>
            <hr/>
            <svg id="radar-display">
                <circle cx="150" cy="100" r="30" fill="none" stroke="rgba(0,255,170,0.15)" stroke-dasharray="2,2"/>
                <circle cx="150" cy="100" r="60" fill="none" stroke="rgba(0,255,170,0.15)" stroke-dasharray="2,2"/>
                <circle cx="150" cy="100" r="90" fill="none" stroke="rgba(0,255,170,0.2)"/>
                <line x1="150" y1="5" x2="150" y2="195" stroke="rgba(0,255,170,0.15)"/>
                <line x1="5" y1="100" x2="295" y2="100" stroke="rgba(0,255,170,0.15)"/>
                <line x1="150" y1="100" x2="240" y2="100" class="radar-sweep" stroke-width="2"/>
                <g id="radar-blips"></g>
            </svg>
        </div>
    </div>

    <div id="diagnostics-tab" class="tab-content">
        <div style="margin: 80px 20px; max-width: 600px;" class="panel">
            <h3>🛠️ CORE DIAGNOSTICS & SYSTEM TUNING</h3>
            <hr/>
            <p>ENGINE HEALTH STATUS: <span id="diag-status" style="color:#ff3333">OFFLINE</span></p>
            <p>SERVER UPTIME RUNNING: <span id="diag-uptime">0</span>s</p>
            <p>CALIBRATION SMOOTHING BUFFER: <span id="diag-buffer">0/5</span> items</p>
            <hr/>
            <h4>🛰️ SIMULATION FLIGHT INJECTOR</h4>
            <p class="meta-stat">Emulates live raw instrument streams when executing code on headless Termux containers.</p>
            <button onclick="toggleSimulation()" id="sim-btn" style="border-color:#ffcc00; color:#ffcc00;">ENGAGE HARDWARE SIMULATOR</button>
            <button onclick="clearSystemLogs()" style="border-color:#ff3333; color:#ff3333;">WIPE SQL & FLAT LOGS</button>
        </div>
    </div>

    <div id="panel-bottom" class="panel">
        <h3>⚙️ COCKPIT CONTROLS</h3>
        <hr/>
        <button onclick="window.location.href='/api/export/csv'">EXPORT CSV</button>
        <button onclick="window.location.href='/api/export/geojson'">COMPILE GIS</button>
    </div>

    <script>
        const ws = new WebSocket(`ws://${window.location.host}`);
        let simulationInterval = null;

        // --- ADD-ON 17: Tab Routing Engine ---
        function switchTab(tabId) {
            document.querySelectorAll('.tab-content').forEach(el => el.classList.remove('active'));
            document.querySelectorAll('.tab-btn').forEach(el => el.classList.remove('active'));
            document.getElementById(`${tabId}-tab`).classList.add('active');
            event.target.classList.add('active');
            if(tabId === 'diagnostics') fetchDiagnostics();
        }

        ws.onmessage = (event) => {
            const data = JSON.parse(event.data);
            document.getElementById('val-alpha').innerText = data.alpha.toFixed(2);
            document.getElementById('val-beta').innerText = data.beta.toFixed(2);
            document.getElementById('val-gamma').innerText = data.gamma.toFixed(2);
            document.getElementById('gps-coords').innerText = `GPS: ${data.gps.lat.toFixed(5)}°N, ${data.gps.lon.toFixed(5)}°W`;
            
            if (data.match) {
                document.getElementById('m-name').innerText = data.match.name;
                document.getElementById('m-name').style.color = data.match.color;
                document.getElementById('m-form').innerText = data.match.formula;
                document.getElementById('m-conf').innerText = data.match.confidence;
                document.getElementById('target-status').innerText = `TARGET FIXED: ${data.match.name.toUpperCase()}`;
                
                // --- ADD-ON 18: Radar Vector Spot Positioning Plotting ---
                plotRadarBlip(data.alpha, data.beta, data.match.color);
            } else {
                document.getElementById('m-name').innerText = "Void";
                document.getElementById('m-name').style.color = "#00ffaa";
                document.getElementById('m-form').innerText = "-";
                document.getElementById('m-conf').innerText = "0.0";
                document.getElementById('target-status').innerText = "STATUS: SEARCHING INTERSECTIONS";
            }
        };

        // --- ADD-ON 18: Dynamic SVG Scale Projections ---
        function plotRadarBlip(alpha, beta, color) {
            const blipGroup = document.getElementById('radar-blips');
            // Project alpha to 0-360 mapped wrapping bounds, beta to radius
            const angle = (alpha % 360) * (Math.PI / 180);
            const radius = Math.min(90, Math.abs(beta - 40) * 2); // Center localized view offset around target zones
            
            const x = 150 + radius * Math.cos(angle);
            const y = 100 + radius * Math.sin(angle);

            const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle");
            circle.setAttribute("cx", x);
            circle.setAttribute("cy", y);
            circle.setAttribute("r", "4");
            circle.setAttribute("fill", color);
            circle.setAttribute("opacity", "0.9");
            
            blipGroup.appendChild(circle);
            if (blipGroup.children.length > 20) blipGroup.removeChild(blipGroup.firstChild);
        }

        // --- ADD-ON 19: Hardware Emulation Streaming Layer Engine ---
        function toggleSimulation() {
            const btn = document.getElementById('sim-btn');
            if (simulationInterval) {
                clearInterval(simulationInterval);
                simulationInterval = null;
                btn.innerText = "ENGAGE HARDWARE SIMULATOR";
                btn.style.color = "#ffcc00";
                btn.style.borderColor = "#ffcc00";
            } else {
                btn.innerText = "HALT SIMULATOR LOOPS";
                btn.style.color = "#ff3333";
                btn.style.borderColor = "#ff3333";
                
                simulationInterval = setInterval(() => {
                    // Generate pseudo-random walks across the mineral coordinate matrices
                    const dice = Math.random();
                    let alpha = 0, beta = 0;
                    
                    if (dice < 0.2) { alpha = 25 + Math.random() * 10; beta = 50 + Math.random() * 10; } // Gold bounds
                    else if (dice < 0.4) { alpha = 60 + Math.random() * 40; beta = 15 + Math.random() * 20; } // Hematite
                    else { alpha = Math.random() * 360; beta = Math.random() * 90; } // Empty Spaced Void Mapping

                    fetch('/api/telemetry/ingest', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ alpha, beta, gamma: Math.random() * 5 })
                    });
                }, 800);
            }
        }

        function fetchDiagnostics() {
            fetch('/api/health')
                .then(res => res.json())
                .then(data => {
                    const statusEl = document.getElementById('diag-status');
                    statusEl.innerText = data.status.toUpperCase();
                    statusEl.style.color = data.status === "online" ? "#00ffaa" : "#ff3333";
                    document.getElementById('diag-uptime').innerText = Math.floor(data.uptime);
                    document.getElementById('diag-buffer').innerText = `${data.buffer_depth}/${data.window_limit}`;
                });
        }
    </script>
</body>
</html>
EOF