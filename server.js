// server.js
// Avvio: node server.js
//
// Requisiti in package.json:
//   "type": "module"
//   dipendenze: express, dotenv, @web3-storage/w3up-client
//
// .env richieste:
//   W3_EMAIL=...
//   W3_SPACE_DID=did:...
//   PORT=8787

import 'dotenv/config'
import express from 'express'
import { create } from '@web3-storage/w3up-client'
import { StoreMemory } from '@web3-storage/w3up-client/stores/memory'

const app = express()
app.use(express.json({ limit: '20mb' }))

// --- Inizializza w3up client con store in-memory ---
const store = new StoreMemory()
const client = await create({ store })

const email = process.env.W3_EMAIL
if (!email) throw new Error('Manca W3_EMAIL nel .env')
await client.login(email)

const spaceDid = process.env.W3_SPACE_DID
if (!spaceDid) throw new Error('Manca W3_SPACE_DID nel .env')
await client.setCurrentSpace(spaceDid)

// --- KV in-memory per demo (sostituisci con DB in produzione) ---
const kv = new Map()

// --- Healthcheck ---
app.get('/health', (_, res) => res.json({ ok: true }))

// --- Upload cifrato verso Web3.Storage ---
app.post(['/ipfs/upload', '/upload'], async (req, res) => {
  try {
    const { recordId, name, dataBase64, bytesBase64 } = req.body || {}
    const b64 = dataBase64 || bytesBase64
    if (!recordId || !b64) {
      return res.status(400).json({ error: 'recordId e dataBase64/bytesBase64 sono obbligatori' })
    }

    const bytes = Buffer.from(b64, 'base64')
    const blob = new Blob([bytes], { type: 'application/octet-stream' })
    const fileName = name || `${recordId}.bin`

    const cid = await client.uploadFile(blob, { name: fileName })
    const cidStr = cid.toString()

    return res.json({
      ok: true,
      cid: cidStr,
      url: `https://${cidStr}.ipfs.w3s.link/${encodeURIComponent(fileName)}`,
      size: bytes.length,
    })
  } catch (err) {
    console.error('Upload error:', err)
    return res.status(500).json({ error: String(err) })
  }
})

// --- Salva/recupera MANIFEST (key wraps) ---
app.post('/keywraps', async (req, res) => {
  try {
    const { recordId, cid, manifest } = req.body || {}
    if (!recordId || !cid || !manifest) {
      return res.status(400).json({ error: 'recordId, cid e manifest sono obbligatori' })
    }
    // TODO: autenticazione (legare al DID dell’utente / UCAN / token)
    kv.set(`wrap:${recordId}`, JSON.stringify({ recordId, cid, manifest, ts: Date.now() }))
    return res.json({ ok: true })
  } catch (err) {
    console.error('Keywraps error:', err)
    return res.status(500).json({ error: String(err) })
  }
})

app.get('/keywraps/:recordId', (req, res) => {
  const rec = kv.get(`wrap:${req.params.recordId}`)
  if (!rec) return res.status(404).json({ error: 'not found' })
  return res.json(JSON.parse(rec))
})

// --- Recovery (backup URK cifrata con passphrase) ---
app.post('/recovery/urk/save', (req, res) => {
  const { userDid, urkWrapped, salt, nonce, kdf, iter, aad, v } = req.body || {}
  if (!userDid || !urkWrapped || !salt || !nonce || !kdf || !iter || !aad || !v) {
    return res.status(400).json({ error: 'campi mancanti' })
  }
  kv.set(`recovery:${userDid}`, JSON.stringify({ userDid, urkWrapped, salt, nonce, kdf, iter, aad, v, ts: Date.now() }))
  return res.json({ ok: true })
})

app.get('/recovery/urk/:did', (req, res) => {
  const rec = kv.get(`recovery:${req.params.did}`)
  if (!rec) return res.status(404).json({ error: 'not found' })
  return res.json(JSON.parse(rec))
})

const port = process.env.PORT || 8787
app.listen(port, () => {
  console.log(`w3up uploader listening on http://localhost:${port}`)
  console.log(`Space: ${spaceDid}`)
})
