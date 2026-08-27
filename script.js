(function() {
  var now = new Date();
  var launchDate = new Date(now.getTime());
  launchDate.setDate(launchDate.getDate() + 14);
  var daysEl = document.getElementById('days');
  var hoursEl = document.getElementById('hours');
  var minutesEl = document.getElementById('minutes');
  var secondsEl = document.getElementById('seconds');
  function pad(n) { return String(n).padStart(2, '0'); }
  function updateTimer() {
    var diff = launchDate.getTime() - Date.now();
    if (diff <= 0) {
      daysEl.textContent = '00'; hoursEl.textContent = '00';
      minutesEl.textContent = '00'; secondsEl.textContent = '00';
      return;
    }
    var days = Math.floor(diff / (1000 * 60 * 60 * 24));
    var hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
    var minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60));
    var seconds = Math.floor((diff % (1000 * 60)) / 1000);
    daysEl.textContent = pad(days);
    hoursEl.textContent = pad(hours);
    minutesEl.textContent = pad(minutes);
    secondsEl.textContent = pad(seconds);
  }
  updateTimer();
  setInterval(updateTimer, 1000);
})();

document.getElementById('subscribeForm').addEventListener('submit', function(e) {
  e.preventDefault();
  var email = this.querySelector('input[type="email"]');
  if (email.value.trim() !== '') {
    alert('Отлично! ' + email.value + ' — вы в списке первых. Ждите новостей.');
    email.value = '';
  } else {
    alert('Пожалуйста, введите email.');
  }
});

document.querySelectorAll('a[data-alert]').forEach(function(a) {
  a.addEventListener('click', function(e) {
    e.preventDefault();
    alert(a.getAttribute('data-alert'));
  });
});

(function() {
  var canvas = document.getElementById('network-canvas');
  var ctx = canvas.getContext('2d');
  var width, height;
  var mouseX = 0.5, mouseY = 0.5;
  var targetMouseX = 0.5, targetMouseY = 0.5;
  var NODE_COUNT = 80;
  var CONNECT_DIST = 150;
  var NODE_RADIUS = 2.5;
  var MOUSE_INFLUENCE = 180;
  var MOUSE_FORCE = 1.8;
  var nodes = [];
  function resize() {
    width = canvas.width = window.innerWidth;
    height = canvas.height = window.innerHeight;
    createNodes();
  }
  function createNodes() {
    nodes = [];
    for (var i = 0; i < NODE_COUNT; i++) {
      nodes.push({
        x: Math.random() * width,
        y: Math.random() * height,
        vx: (Math.random() - 0.5) * 0.5,
        vy: (Math.random() - 0.5) * 0.5,
        baseX: 0, baseY: 0,
        radius: NODE_RADIUS + (Math.random() - 0.5) * 1.5
      });
    }
    nodes.forEach(function(n) { n.baseX = n.x; n.baseY = n.y; });
  }
  window.addEventListener('resize', resize);
  resize();
  document.addEventListener('mousemove', function(e) {
    targetMouseX = e.clientX / width;
    targetMouseY = e.clientY / height;
  });
  document.addEventListener('touchmove', function(e) {
    var touch = e.touches[0];
    if (touch) { targetMouseX = touch.clientX / width; targetMouseY = touch.clientY / height; }
  }, { passive: true });
  function smoothMouse() {
    mouseX += (targetMouseX - mouseX) * 0.08;
    mouseY += (targetMouseY - mouseY) * 0.08;
  }
  function updateNodes() {
    var mouseWorldX = mouseX * width;
    var mouseWorldY = mouseY * height;
    nodes.forEach(function(n) {
      n.vx += (n.baseX - n.x) * 0.012;
      n.vy += (n.baseY - n.y) * 0.012;
      var dx = n.x - mouseWorldX;
      var dy = n.y - mouseWorldY;
      var dist = Math.sqrt(dx * dx + dy * dy);
      if (dist < MOUSE_INFLUENCE && dist > 0.5) {
        var force = (MOUSE_INFLUENCE - dist) / MOUSE_INFLUENCE * MOUSE_FORCE;
        n.vx += (dx / dist) * force * 0.4;
        n.vy += (dy / dist) * force * 0.4;
      }
      nodes.forEach(function(other) {
        if (other === n) return;
        var dx2 = n.x - other.x;
        var dy2 = n.y - other.y;
        var dist2 = Math.sqrt(dx2 * dx2 + dy2 * dy2);
        if (dist2 < CONNECT_DIST && dist2 > 0.5) {
          var force = (CONNECT_DIST - dist2) / CONNECT_DIST * 0.02;
          n.vx += (dx2 / dist2) * force * 0.3;
          n.vy += (dy2 / dist2) * force * 0.3;
        }
      });
      n.vx *= 0.94;
      n.vy *= 0.94;
      n.x += n.vx;
      n.y += n.vy;
      n.x = Math.max(0, Math.min(width, n.x));
      n.y = Math.max(0, Math.min(height, n.y));
    });
  }
  function draw() {
    ctx.clearRect(0, 0, width, height);
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        var dx = nodes[i].x - nodes[j].x;
        var dy = nodes[i].y - nodes[j].y;
        var dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < CONNECT_DIST) {
          var alpha = 0.15 * (1 - dist / CONNECT_DIST);
          ctx.beginPath();
          ctx.moveTo(nodes[i].x, nodes[i].y);
          ctx.lineTo(nodes[j].x, nodes[j].y);
          ctx.strokeStyle = 'rgba(165, 180, 252, ' + alpha + ')';
          ctx.lineWidth = 1.2;
          ctx.stroke();
        }
      }
    }
    nodes.forEach(function(n) {
      ctx.shadowColor = 'rgba(99, 102, 241, 0.2)';
      ctx.shadowBlur = 12;
      ctx.beginPath();
      ctx.arc(n.x, n.y, n.radius, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(165, 180, 252, 0.6)';
      ctx.fill();
      ctx.shadowBlur = 0;
      ctx.beginPath();
      ctx.arc(n.x, n.y, n.radius * 0.4, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(220, 230, 255, 0.8)';
      ctx.fill();
      ctx.shadowBlur = 0;
    });
    var mouseWorldX = mouseX * width;
    var mouseWorldY = mouseY * height;
    var gradient = ctx.createRadialGradient(
      mouseWorldX, mouseWorldY, 0,
      mouseWorldX, mouseWorldY, MOUSE_INFLUENCE
    );
    gradient.addColorStop(0, 'rgba(99, 102, 241, 0.03)');
    gradient.addColorStop(1, 'rgba(99, 102, 241, 0)');
    ctx.beginPath();
    ctx.arc(mouseWorldX, mouseWorldY, MOUSE_INFLUENCE, 0, Math.PI * 2);
    ctx.fillStyle = gradient;
    ctx.fill();
  }
  function animate() {
    smoothMouse();
    updateNodes();
    draw();
    requestAnimationFrame(animate);
  }
  animate();
})();
