import os

os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["OMP_NUM_THREADS"] = "1"

from underdog_woof import Woof


class InterruptibleWoof(Woof):
    def _piece(self, text):
        if not self.is_current.getAsBoolean():
            raise InterruptedError("Narration stopped")
        return super()._piece(text)


class Renderer:
    def __init__(self, weights):
        self.weights = weights
        self.voice = None
        self.model = None

    def synthesize(self, text, voice, is_current):
        if voice != self.voice:
            self.model = None
            self.voice = None
            self.model = InterruptibleWoof(weights=self.weights, voice=voice)
            self.voice = voice
        self.model.is_current = is_current
        try:
            return self.model(text, seed=0).astype("<f4", copy=False).tobytes()
        finally:
            self.model.is_current = None
