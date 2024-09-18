module main

import os
import veb
import log
import time
import term
import net
import net.http
import net.websocket
import json 

const app_port = 8990

fn main() {
	mut x := map[string]Session
	x["test"] = Session{
		name: "test",
		chat: new_chat_server() or {panic("Ahhhhh")}
	}
	mut app := &App{
		sessions: x
		}
	app.mount_static_folder_at(os.resource_abs_path('assets'), '/assets')!
	app.serve_static('/favicon.ico', os.resource_abs_path('assets/favicon.ico'))!
	veb.run[App, Context](mut app, app_port)
}

pub struct Context {
	veb.Context
}

pub struct Session{
	name string
mut:
	chat &websocket.Server
}

pub struct App {
	veb.StaticHandler
mut:
	sessions map[string]Session
}

@["/:session/:user/game"]
pub fn (mut app App) index(mut ctx Context, session string, user string) veb.Result {
	return $veb.html()
}

@["/:session/chat"]
pub fn (mut app App) chat(mut ctx Context, session string) veb.Result {
	key := ctx.get_header(http.CommonHeader.sec_websocket_key) or { '' }
	if key == '' {
		ctx.error('Invalid websocket handshake. Key is missing.')
		return ctx.redirect('/')
	}
	x := &app.sessions[session] or {return ctx.text("Probably session (${session}) not found.")}.chat
	dump(ctx.req.cookie('token') or { http.Cookie{} }.value)
	wlog('> transferring connection with key: ${key}, to the websocket server ${voidptr(*x)} ...')
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	spawn fn (mut wss websocket.Server, mut connection net.TcpConn, key string) {
		wss.handle_handshake(mut connection, key) or { wlog('handle_handshake error: ${err}') }
		wlog('>> wss.handle_handshake finished, key: ${key}')
	}(mut *x, mut ctx.conn, key)
	wlog('> done transferring connection')
	return veb.no_result()
}

fn slog(message string) {
	eprintln(term.colorize(term.bright_yellow, message))
}

fn wlog(message string) {
	eprintln(term.colorize(term.bright_blue, message))
}

fn new_chat_server() !&websocket.Server {
	mut logger := &log.Log{}
	logger.set_level(.info)
	mut wss := websocket.new_server(.ip, app_port, '', logger: logger)
	wss.set_ping_interval(100)
	wss.on_connect(fn [mut logger] (mut server_client websocket.ServerClient) !bool {
		server_client.client.logger = logger
		return true
	})!
	wss.on_close(fn (mut client websocket.Client, code int, reason string) ! {
		slog('wss.on_close client.id: ${client.id} | code: ${code}, reason: ${reason}')
	})
	wss.on_message(fn [mut wss] (mut client websocket.Client, msg &websocket.Message) ! {
		txt := json.decode(map[string]string, msg.payload.bytestr())!["message-input"].replace("<","&lt;").replace(">","&gt;").replace("&","&amp;")
		name := json.decode(map[string]string, msg.payload.bytestr())!["name"].replace("<","&lt;").replace(">","&gt;").replace("&","&amp;")
		slog('${client.conn.peer_ip() or {"BROKEN"}} says: "${txt}"')
		text := '<ul hx-swap-oob="beforeend" id="chat"><br/><b>${name}(${client.conn.peer_ip() or {"BROKEN"}})</b> says: ${txt}</ul>'
		// client.write_string(text) or { slog('client.write err: ${err}') return err }
		for _, mut c in lock wss.server_state {
			wss.server_state.clients
		} {
			if c.client.get_state() == .open {
				c.client.write_string(text) or {
					slog('error while broadcasting to i: ${voidptr(c)}, err: ${err}')
					continue
				}
			}
		}})

	slog('Websocket Server initialized, wss: ${voidptr(wss)}')
	return wss
}
