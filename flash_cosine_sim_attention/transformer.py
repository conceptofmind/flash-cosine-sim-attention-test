import torch
from torch import nn
import torch.nn.functional as F

from einops import rearrange

from flash_cosine_sim_attention.flash_cosine_sim_attention import plain_cosine_sim_attention, flash_cosine_sim_attention

# helper function

def exists(val):
    return val is not None

def eval_decorator(fn):
    def inner(model, *args, **kwargs):
        was_training = model.training
        model.eval()
        out = fn(model, *args, **kwargs)
        model.train(was_training)
        return out
    return inner

# top k filtering

def top_k(logits, thres = 0.9):
    k = int((1 - thres) * logits.shape[-1])
    val, ind = torch.topk(logits, k)
    probs = torch.full_like(logits, float('-inf'))
    probs.scatter_(1, ind, val)
    return probs

class AutoregressiveWrapper(nn.Module):
    def __init__(self, net, pad_value = 0):
        super().__init__()
        self.max_seq_len = net.max_seq_len
        self.pad_value = pad_value
        self.net = net

    @torch.no_grad()
    @eval_decorator
    def generate(self, start_tokens, seq_len, temperature = 1., filter_thres = 0.9, **kwargs):
        b, n, device = *start_tokens.shape, start_tokens.device

        out = start_tokens

        for _ in range(seq_len):
            logits = self.net(out[:, -self.max_seq_len:], **kwargs)[:, -1, :]
            filtered_logits = top_k(logits, thres = filter_thres)
            probs = F.softmax(filtered_logits / temperature, dim = -1)
            sample = torch.multinomial(probs, 1)
            out = torch.cat((out, sample), dim = -1)

        return out[:, n:]

    def forward(self, x, **kwargs):
        x_inp, x_labels = x[:, :-1], x[:, 1:]
        logits = self.net(x_inp, **kwargs)
        return F.cross_entropy(rearrange(logits, 'b c n -> b n c'), x_labels)

# attention and feedforward

def FeedForward(dim, mult = 4):
    dim_hidden = int(dim * mult)
    return nn.Sequential(
        nn.LayerNorm(dim),
        nn.Linear(dim, dim_hidden),
        nn.GELU(),
        nn.Linear(dim_hidden, dim)
    )

class Attention(nn.Module):
    def __init__(
        self,
        dim,
        dim_head = 64,
        heads = 8
    ):
        super().__init__()
        inner_dim = dim_head * heads
        self.heads = heads
        self.norm = nn.LayerNorm(dim)

        self.to_qkv = nn.Linear(dim, inner_dim * 3, bias = False)
        self.to_out = nn.Linear(inner_dim, dim, bias = False)

    def forward(self, x):
        h = self.heads
        x = self.norm(x)

        q, k, v = self.to_qkv(x).chunk(3, dim = -1)
        q, k, v = map(lambda t: rearrange(t, 'b n (h d) -> b h n d', h = h), (q, k, v))

        o = plain_cosine_sim_attention(q, k, v, causal = True)

        o = rearrange(o, 'b h n d -> b n (h d)')
        return self.to_out(o)

# transformer for testing

class CosineSimCausalTransformer(nn.Module):
    def __init__(
        self,
        *,
        num_tokens,
        dim,
        max_seq_len,
        depth,
        heads = 8,
        dim_head = 64
    ):
        super().__init__()
        self.max_seq_len = max_seq_len

        self.token_emb = nn.Embedding(num_tokens, dim)
        self.pos_emb = nn.Embedding(max_seq_len, dim)

        self.layers = nn.ModuleList([])
        for _ in range(depth):
            self.layers.append(nn.ModuleList([
                Attention(dim, dim_head = dim_head, heads = heads),
                FeedForward(dim)
            ]))

        self.to_logits = nn.Sequential(
            nn.LayerNorm(dim),
            nn.Linear(dim, num_tokens)
        )

    def forward(self, x):
        x = self.token_emb(x)
        x = x + self.pos_emb(torch.arange(x.shape[1], device = x.device))

        for attn, ff in self.layers:
            x = attn(x) + x
            x = ff(x) + x

        logits = self.to_logits(x)
        return logits
