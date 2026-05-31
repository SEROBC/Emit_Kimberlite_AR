// app_v2.js

window.addEventListener('DOMContentLoaded', () => {
  initUsgsPipeline();
});

function initUsgsPipeline() {
  // --- STATE ---
  let userCoords = null;
  let routingLine = null;
  let selectedTarget = null;
  let radarVisible = true;
  let scanActive = false;
  let compositionInterval = null;
  const renderedEntities = new Set();

  // --- HUD NOTIFICATIONS ---
  window.postNotification = function (msg, prefix = 'SYS_ALERT') {
    const feed = document.getElementById('toast-feed');
    if (!feed) return;
    const toast = document.createElement('div');
    toast.className = 'toast-msg';
    toast.innerText = `${prefix} // ${msg}`;
    feed.appendChild(toast);
    setTimeout(() => toast.remove(), 4500);
  };

  // --- MAP INIT (DARK + ESRI OPTION) ---
  const map = L.map('map', {
    center: [34.0522, -118.2437],
    zoom: 15,
    zoomControl: false,
    attributionControl: false
  });

  const darkLayer = L.tileLayer(
    'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
    { maxZoom: 22 }
  ).addTo(map);

  const esriLayer = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{x}/{y}',
    { maxZoom: 19 }
  );

  let usingEsri = false;

  function toggleBaseLayer() {
    if (usingEsri) {
      map.removeLayer(esriLayer);
      darkLayer.addTo(map);
      usingEsri = false;
      window.postNotification('REVERTED TO DARK CARTO BASEMAP');
    } else {
      map.removeLayer(darkLayer);
      esriLayer.addTo(map);
      usingEsri = true;
      window.postNotification('ESRI WORLD IMAGERY ENGAGED (KEYLESS HOTFIX)');
    }
  }

  // --- HAVERSINE DISTANCE ---
  function calculateHaversineDistance(coords1, coords2) {
    const R = 6371e3;
    const lat1 = (coords1[0] * Math.PI) / 180;
    const lat2 = (coords2[0] * Math.PI) / 180;
    const dLat = ((coords2[0] - coords1[0]) * Math.PI) / 180;
    const dLon = ((coords2[1] - coords1[1]) * Math.PI) / 180;
    const a =
      Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(lat1) *
        Math.cos(lat2) *
        Math.sin(dLon / 2) *
        Math.sin(dLon / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
  }

  // --- 3D + MAP INJECTION (USGS + SUBSURFACE + MAX) ---
  function inject3DSpatialData(
    lat,
    lon,
    title,
    depthMetres,
    densityFactor,
    hexColor,
    options = {}
  ) {
    const { highPriority = false } = options;
    const entityId = `${lat}_${lon}`;
    if (renderedEntities.has(entityId)) return;
    renderedEntities.add(entityId);

    // Map marker
    const pin = L.circleMarker([lat, lon], {
      radius: highPriority ? 9 : 6,
      fillColor: hexColor,
      color: '#fff',
      weight: 1.5,
      fillOpacity: 1
    }).addTo(map);

    pin.on('click', () => {
      selectedTarget = [lat, lon];
      const feetDepth = Math.floor(depthMetres * 3.28084);
      const hudNav = document.getElementById('hud-nav-text');
      if (userCoords) {
        const distMeters = calculateHaversineDistance(userCoords, selectedTarget);
        const distFeet = Math.floor(distMeters * 3.28084);
        hudNav.innerText = `${title.toUpperCase()} // DEPTH: -${feetDepth}FT // DIST: ${distFeet}FT`;
      } else {
        hudNav.innerText = `${title.toUpperCase()} // DEPTH: -${feetDepth}FT`;
      }
      window.postNotification(`TARGET LOCKED: ${title.toUpperCase()}`);
    });

    // AR scene
    const scene = document.querySelector('a-scene');
    if (!scene) return;

    const anchor = document.createElement('a-entity');
    anchor.setAttribute(
      'gps-entity-place',
      `latitude: ${lat}; longitude: ${lon};`
    );

    // Surface cylinder
    const cylinder = document.createElement('a-cylinder');
    cylinder.setAttribute('class', 'spectral-pillar');
    cylinder.setAttribute('radius', (densityFactor * 10).toString());
    cylinder.setAttribute('height', '100');
    cylinder.setAttribute('position', '0 50 0');
    cylinder.setAttribute(
      'material',
      `color: ${hexColor}; opacity: 0.25; transparent: true; shader: flat;`
    );
    anchor.appendChild(cylinder);

    // Subsurface cylinder (wireframe)
    const subCylinder = document.createElement('a-cylinder');
    subCylinder.setAttribute('class', 'spectral-pillar');
    subCylinder.setAttribute('radius', (densityFactor * 9.5).toString());
    subCylinder.setAttribute('height', '400');
    subCylinder.setAttribute('position', '0 -200 0');
    subCylinder.setAttribute(
      'material',
      `color: ${hexColor}; opacity: 0.45; transparent: true; wireframe: true; shader: flat;`
    );
    anchor.appendChild(subCylinder);

    // Ground ring
    const groundIntersect = document.createElement('a-ring');
    groundIntersect.setAttribute('radius-inner', '10');
    groundIntersect.setAttribute('radius-outer', '12');
    groundIntersect.setAttribute('position', '0 0 0');
    groundIntersect.setAttribute('rotation', '90 0 0');
    groundIntersect.setAttribute(
      'material',
      'color: #ffffff; opacity: 0.7; shader: flat; side: double;'
    );
    anchor.appendChild(groundIntersect);

    // Depth marker + sonar grid
    const visualDepthY = -Math.min(depthMetres, 250);

    const depthMarker = document.createElement('a-ring');
    depthMarker.setAttribute('radius-inner', '14');
    depthMarker.setAttribute('radius-outer', '16');
    depthMarker.setAttribute('position', `0 ${visualDepthY} 0`);
    depthMarker.setAttribute('rotation', '90 0 0');
    depthMarker.setAttribute(
      'material',
      `color: #ffcc00; opacity: 0.9; shader: flat; side: double;`
    );
    anchor.appendChild(depthMarker);

    const sonarRing = document.createElement('a-ring');
    sonarRing.setAttribute('class', 'subsurface-grid');
    sonarRing.setAttribute('radius-inner', '0');
    sonarRing.setAttribute('radius-outer', '25');
    sonarRing.setAttribute('position', `0 ${visualDepthY} 0`);
    sonarRing.setAttribute('rotation', '90 0 0');
    sonarRing.setAttribute(
      'material',
      'color: #ff3366; opacity: 0.2; shader: flat; side: double; wireframe: true;'
    );
    sonarRing.setAttribute('visible', 'false');
    anchor.appendChild(sonarRing);

    // Info label
    const labelFeet = Math.floor(depthMetres * 3.28084);
    const infoLabel = document.createElement('a-text');
    infoLabel.setAttribute(
      'value',
      `${title} STRATA DEPTH: -${labelFeet}FT`
    );
    infoLabel.setAttribute('scale', '16 16 16');
    infoLabel.setAttribute('position', '0 65 0');
    infoLabel.setAttribute('align', 'center');
    infoLabel.setAttribute('look-at', '[gps-camera]');
    anchor.appendChild(infoLabel);

    // High-priority diamond (MAX)
    if (highPriority) {
      const diamondContainer = document.createElement('a-entity');
      diamondContainer.setAttribute('class', 'diamond-geo');
      diamondContainer.setAttribute('position', '0 9 0');
      diamondContainer.setAttribute(
        'animation',
        'property: rotation; to: 0 360 0; loop: true; dur: 4500; easing: linear;'
      );
      const topCone = document.createElement('a-cone');
      topCone.setAttribute('radius-bottom', '5.5');
      topCone.setAttribute('height', '7.5');
      topCone.setAttribute('position', '0 3.75 0');
      topCone.setAttribute(
        'material',
        `color: ${hexColor}; opacity: 0.85; wireframe: true; shader: flat;`
      );
      diamondContainer.appendChild(topCone);
      anchor.appendChild(diamondContainer);
    }

    scene.appendChild(anchor);
  }

  // --- USGS LIVE PIPELINE ---
  async function fetchLiveGeologicalData(lat, lon) {
    window.postNotification('QUERYING LIVE USGS GLOBAL DATA MATRIX...');
    const offset = 0.08;
    const url = `https://mrdata.usgs.gov/mrds/wfs?request=GetFeature&service=WFS&version=1.1.0&typeName=mrds&outputFormat=json&bbox=${lat - offset},${lon - offset},${lat + offset},${lon + offset}`;

    try {
      const response = await fetch(url);
      if (!response.ok) throw new Error('Network latency fault');
      const data = await response.json();
      if (!data.features || data.features.length === 0) {
        useFallbackSimulationGrid(lat, lon);
        return;
      }

      window.postNotification(
        `SUCCESS: ${data.features.length} USGS TARGETS INTERCEPTED`
      );

      data.features.slice(0, 15).forEach((feat, index) => {
        const coords = feat.geometry.coordinates;
        const props = feat.properties;
        const name = props.site_name || `USGS Deposit Sector ${index + 1}`;
        const commodity = (props.commod1 || 'Mineral Point')
          .split(',')[0]
          .trim();

        let color = '#00ffcc';
        if (/gold|silver|platinum|copper/i.test(commodity)) color = '#ffcc00';
        if (/iron|uranium|thorium|lead/i.test(commodity)) color = '#ff3333';

        const calculatedDepth = Math.floor(Math.random() * 180) + 30;
        const density = parseFloat((Math.random() * 0.4 + 0.5).toFixed(2));

        inject3DSpatialData(
          coords[1],
          coords[0],
          `${name} (${commodity})`,
          calculatedDepth,
          density,
          color,
          { highPriority: /kimberlite|diamond/i.test(commodity) }
        );
      });
    } catch (error) {
      useFallbackSimulationGrid(lat, lon);
    }
  }

  function useFallbackSimulationGrid(lat, lon) {
    const localSectors = [
      {
        name: 'EMIT Kimberlite Target Alpha',
        offsetLat: 0.0015,
        offsetLon: 0.0015,
        depth: 145,
        density: 0.85,
        color: '#00ffff',
        highPriority: true
      },
      {
        name: 'USGS Rare Earth Bed Bravo',
        offsetLat: -0.0012,
        offsetLon: 0.0022,
        depth: 88,
        density: 0.62,
        color: '#ffcc00',
        highPriority: false
      },
      {
        name: 'Sub-Surface Iron Strike Zone',
        offsetLat: 0.0025,
        offsetLon: -0.0018,
        depth: 210,
        density: 0.95,
        color: '#ff3333',
        highPriority: false
      }
    ];

    localSectors.forEach(s => {
      inject3DSpatialData(
        lat + s.offsetLat,
        lon + s.offsetLon,
        s.name,
        s.depth,
        s.density,
        s.color,
        { highPriority: s.highPriority }
      );
    });

    window.postNotification('FALLBACK SIMULATION GRID ACTIVE');
  }

  // --- HUD CONTROLS (CAMERA / RADAR / SCAN / ROUTE) ---
  window.triggerAction = function (type) {
    const statusTag = document.getElementById('status-tag');
    const hudNav = document.getElementById('hud-nav-text');
    const reticle = document.getElementById('targeting-matrix');
    const analysisPanel = document.getElementById('composition-analysis');
    const videoElement = document.querySelector('video');

    if (type === 'camera') {
      if (!videoElement) return;
      if (videoElement.dataset.mode === 'max') {
        videoElement.dataset.mode = '';
        videoElement.style.filter = '';
        window.postNotification('STANDARD SPECTRUM RESTORED', 'MAX_SYS');
      } else {
        videoElement.dataset.mode = 'max';
        videoElement.style.filter =
          'contrast(1.7) brightness(1.2) hue-rotate(300deg) sepia(0.3)';
        window.postNotification(
          'APERTURE INFRARED REFRACTION MATRIX TOGGLED',
          'MAX_SYS'
        );
      }
    } else if (type === 'map') {
      radarVisible = !radarVisible;
      document.getElementById('radar-container').style.display = radarVisible
        ? 'block'
        : 'none';
      toggleBaseLayer();
    } else if (type === 'scan') {
      scanActive = !scanActive;
      statusTag.innerText = scanActive ? 'SCANNING' : 'READY';
      statusTag.style.borderColor = scanActive ? '#ff00ff' : '#00ffcc';
      statusTag.style.color = scanActive ? '#ff00ff' : '#00ffcc';

      document
        .querySelectorAll('.spectral-pillar')
        .forEach(p => {
          p.setAttribute(
            'material',
            `wireframe: ${scanActive}; opacity: ${
              scanActive ? 0.9 : 0.3
            }; transparent: true;`
          );
        });
      document
        .querySelectorAll('.subsurface-grid')
        .forEach(g => g.setAttribute('visible', scanActive.toString()));

      if (scanActive) {
        if (reticle) reticle.classList.add('scanning');
        if (analysisPanel) analysisPanel.style.display = 'block';
        window.postNotification(
          'MAX ENERGETIC WAVE EMITTER ACTIVE // SCANNING SURFACE',
          'MAX_SYS'
        );
        compositionInterval = setInterval(() => {
          const ilm = document.getElementById('bar-ilm');
          const gar = document.getElementById('bar-gar');
          const oli = document.getElementById('bar-oli');
          if (ilm) ilm.style.width = `${Math.floor(Math.random() * 20) + 75}%`;
          if (gar) gar.style.width = `${Math.floor(Math.random() * 15) + 82}%`;
          if (oli) oli.style.width = `${Math.floor(Math.random() * 25) + 65}%`;
        }, 400);
      } else {
        if (reticle) reticle.classList.remove('scanning');
        if (analysisPanel) analysisPanel.style.display = 'none';
        if (videoElement && videoElement.dataset.mode !== 'max') {
          videoElement.style.filter = '';
        }
        clearInterval(compositionInterval);
        window.postNotification('SURFACE APERTURE TERMINATED // ARRAY IDLE', 'MAX_SYS');
      }
    } else if (type === 'route') {
      if (!selectedTarget || !userCoords) {
        window.postNotification('ERR: TRACKING LOCK REQUIREMENT UNFULFILLED');
        return;
      }
      if (routingLine) map.removeControl(routingLine);
      routingLine = L.polyline([userCoords, selectedTarget], {
        color: '#ff3366',
        weight: 5,
        dashArray: '6, 6'
      }).addTo(map);
      const exactMeters = calculateHaversineDistance(userCoords, selectedTarget);
      window.postNotification(
        `VECTOR CALCULATED: ${Math.floor(exactMeters)} METERS TO TARGET BASELINE`
      );
      hudNav.innerHTML =
        '<span style="color:#ff3366;">NAV LOCK:</span> VECTOR ACQUIRED.';
      map.fitBounds(routingLine.getBounds(), { padding: [20, 20] });
    }
  };

  // --- GEOLOCATION + INITIAL SYNC ---
  navigator.geolocation.watchPosition(
    pos => {
      const { latitude, longitude } = pos.coords;
      const initialSync = userCoords === null;
      userCoords = [latitude, longitude];
      map.setView(userCoords, 16);

      if (window.userMarker) {
        window.userMarker.setLatLng(userCoords);
      } else {
        window.userMarker = L.marker(userCoords, {
          icon: L.divIcon({ className: 'user-location-pulse' })
        }).addTo(map);
        const statusTag = document.getElementById('status-tag');
        const hudNav = document.getElementById('hud-nav-text');
        if (statusTag) statusTag.innerText = 'READY';
        if (hudNav)
          hudNav.innerText =
            'LIVE NASA/USGS DATA MATRIX INSTANTIATED. READY.';
      }

      if (initialSync) {
        // High-priority local kimberlite anchor
        inject3DSpatialData(
          latitude + 0.0012,
          longitude + 0.0018,
          'Kimberlite Surface Pipe Alpha',
          120,
          0.96,
          '#ff00ff',
          { highPriority: true }
        );
        fetchLiveGeologicalData(latitude, longitude);
      }
    },
    err => {
      window.postNotification(
        'GPS POSITION SYNC TIMEOUT: CHECK DEVICE ENVIRONMENT'
      );
    },
    { enableHighAccuracy: true, maximumAge: 0 }
  );

  window.postNotification('SYSTEM HUD MATRIX ONLINE // INIT_USGS_PIPELINE READY');
}
