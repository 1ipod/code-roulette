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

const path = "/usr/bin/echo"
const args = ["echo", "agojisgodjpaspdgajsdgopiasjdgjoiasjdiogaosidgjasjopigjdojsaoipdgpjioasiodgjoiasdjgioapsdgjiopasopdjigijopasdjgooaipsdigjoasijodgjiopasjdgioasdjigoaijosdgjiasijdogjiasdiopgjpaiosdgjioasoijdgjopiasjdoipgjiopasdjgioaojispdgjpioasdpijogijopasdjiogjioasdjiopgdsjiopsadjiogjioasgojidgjaisdojipgjasdiopgjoiasoijpdgjiopasdijopgjioasdijgaspiogijsapijogioasdjp"]

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

pub struct ProcIo{
	read fn () string
	write fn (string)
	alive fn () bool
} 

pub struct User{
	name string
	session string
mut:
	terminal Term
}

pub struct Term{
	ProcIo
mut:
	ws &websocket.Server
}

pub struct App {
	veb.StaticHandler
mut:
	sessions map[string]Session
	users shared map[string]User
}

@["/:session/:user/game"]
pub fn (mut app App) index(mut ctx Context, session string, user string) veb.Result {
	return $veb.html()
}


@["/:session/:user/join"]
pub fn (mut app App) new_user(mut ctx Context, session string, user string) veb.Result {
	mut proc := os.new_process(path)
	proc.args = args
	proc.set_redirect_stdio()
	proc.run()
	println(proc)
	x := ProcIo{
		read:  proc.stdout_slurp
		write: proc.stdin_write
		alive: proc.is_alive
	}
	u := User{
			name: user
			session: session
			terminal: Term{
				ws: new_term_session(x) or {panic("${err}")}
				ProcIo: x
			}
	}
	println(u)
	lock app.users{
		app.users[user] = u
		println(app.users)
	}
	return ctx.redirect("/${session}/${user}/game")
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

@["/:session/:user/shell"]
pub fn (mut app App) shell(mut ctx Context, session string, user string) veb.Result {
	key := ctx.get_header(http.CommonHeader.sec_websocket_key) or { '' }
	if key == '' {
		ctx.error('Invalid websocket handshake. Key is missing.')
		return ctx.redirect('/')
	}
	mut x := &websocket.Server{}
	rlock app.users{
		x = app.users[user] or {return ctx.text("Probably session (${session}) not found.")}.terminal.ws
	}
	println(x)
	dump(ctx.req.cookie('token') or { http.Cookie{} }.value)
	wlog('> transferring connection with key: ${key}, to the websocket server ${voidptr(x)} ...')
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	spawn fn (mut wss websocket.Server, mut connection net.TcpConn, key string) {
		wss.handle_handshake(mut connection, key) or { wlog('handle_handshake error: ${err}') }
		wlog('>> wss.handle_handshake finished, key: ${key}')
	}(mut x, mut ctx.conn, key)
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
	wss.set_ping_interval(1000)
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

fn new_term_session(io ProcIo) !&websocket.Server {
	if !io.alive(){
		panic("drunkeness")
	}
	mut logger := &log.Log{}
	logger.set_level(.error)
	mut wss := websocket.new_server(.ip, app_port, '', logger: logger)
	wss.set_ping_interval(1000)
	wss.on_connect(fn [mut logger] (mut server_client websocket.ServerClient) !bool {
		server_client.client.logger = logger
		return true
	})!
	wss.on_close(fn (mut client websocket.Client, code int, reason string) ! {
		slog('wss.on_close client.id: ${client.id} | code: ${code}, reason: ${reason}')
	})
	wss.on_message(fn [mut wss, io] (mut client websocket.Client, msg &websocket.Message) ! {
		txt := json.decode(map[string]string, msg.payload.bytestr())!["term"]
		io.write(txt)
		})
	slog('Websocket Server initialized, wss: ${voidptr(wss)}')
	x := fn [wss, io] (){
		for{
			if rlock wss.server_state {wss.server_state.clients.len} != 0{
				break
			}
			time.sleep(500000000)
		}
		for io.alive(){
			time.sleep(1000000000)
			x := io.read()
				println(x)
				if x in ["","\n"]{
					continue
				}
			for _, mut c in lock wss.server_state {wss.server_state.clients} {
				if c.client.get_state() != .open{
					println("pausing")
					time.sleep(1000000 * 5000)
				}
					if c.client.get_state() == .open {
						c.client.write_string("<ul id='term' hx-swap-oob=\"beforeend\">${x}</ul>".replace("\n","<br>")) or {
							slog('error while broadcasting to i: ${voidptr(c)}, err: ${err}')
							continue
						}
			}
			}
		}
		println("proc's dead")
	}
	spawn x()
	return wss
}