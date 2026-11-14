import initialize, { Model } from "./PhononBindings.js";

async function read(path) {
    const response = await fetch(path);
    if (!response.ok) throw new Error("Phonon resource unavailable: " + path);
    return new Uint8Array(await response.arrayBuffer());
}

let model;
const voices = new Map();
let queue = Promise.resolve();
const channel = new MessageChannel();
let resume;
channel.port1.onmessage = () => resume();

globalThis.preparePhonon = async function () {
    await initialize({ module_or_path: await read("PhononSIMD.wasm") });
    const [weights, tokenizer, config, hugh, spencer] = await Promise.all([
        read("model.q8.gguf"), read("tokenizer.json"), read("config.json"),
        read("Hugh.safetensors"), read("Spencer.safetensors")
    ]);
    model = await Model.load(weights, tokenizer, config, "q8", "en", null, null, "cpu");
    voices.set("Hugh", model.add_voice(hugh));
    voices.set("Spencer", model.add_voice(spencer));
};

const active = new Set();
const cancelled = new Set();
globalThis.cancelPhonon = id => {
    if (active.has(id)) cancelled.add(id);
};

globalThis.speakPhonon = function (id, text, voice) {
    active.add(id);
    const job = queue.then(async () => {
        if (cancelled.has(id)) return null;
        const chunks = [];
        let samples = 0;
        model.start_generation(voices.get(voice), text, 0.3, 4242424242424242n);
        try {
            while (!cancelled.has(id) && model.next_chunk() !== undefined) {
                let frame;
                while (!cancelled.has(id) && (frame = await model.generation_step()) !== undefined) {
                    chunks.push(frame);
                    samples += frame.length;
                    await new Promise(resolve => {
                        resume = resolve;
                        channel.port2.postMessage(null);
                    });
                }
            }
            if (cancelled.has(id)) return null;
            const pcm = new Float32Array(samples);
            let offset = 0;
            for (const chunk of chunks) {
                pcm.set(chunk, offset);
                offset += chunk.length;
            }
            const bytes = new Uint8Array(pcm.buffer);
            let binary = "";
            for (let i = 0; i < bytes.length; i += 16384) {
                binary += String.fromCharCode(...bytes.subarray(i, i + 16384));
            }
            return btoa(binary);
        } finally {
            model.stop_generation();
        }
    }).finally(() => {
        active.delete(id);
        cancelled.delete(id);
    });
    queue = job.catch(() => {});
    return job;
};
