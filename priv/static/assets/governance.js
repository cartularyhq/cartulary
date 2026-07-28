// SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

import {Socket} from "/vendor/phoenix/phoenix.mjs"
import {LiveSocket} from "/vendor/phoenix_live_view/phoenix_live_view.esm.js"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})

liveSocket.connect()
window.liveSocket = liveSocket
