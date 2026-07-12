import net from "node:net";

const blocked = [
  ["169.254.169.254", 80, "cloud metadata"],
  ["10.96.0.1", 443, "Kubernetes API"],
  ["192.168.65.254", 3001, "Rails control plane"],
];

for (const [host, port, name] of blocked) {
  await new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port });
    const timer = setTimeout(() => {
      socket.destroy();
      resolve();
    }, 750);
    socket.once("connect", () => {
      clearTimeout(timer);
      socket.destroy();
      reject(new Error(`${name} was reachable`));
    });
    socket.once("error", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}