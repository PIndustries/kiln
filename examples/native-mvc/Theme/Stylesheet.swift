import Foundation
import KilnWeb

extension ExampleWeb {
    static let css = """
    :root{
        color-scheme:dark;
        --bg:#080c09;
        --panel:#111912;
        --text:#e3f0e6;
        --accent:#64f58c;
        --muted:#91aa99
    }
    *{box-sizing:border-box}
    body{
        margin:0;
        background:var(--bg);
        color:var(--text);
        font:17px/1.6 ui-sans-serif,system-ui,sans-serif
    }
    main{max-width:960px;margin:0 auto;padding:64px 32px}
    header{
        display:flex;
        justify-content:space-between;
        gap:24px;
        color:var(--accent);
        font:12px ui-monospace,monospace;
        letter-spacing:.12em
    }
    h1{
        font-size:clamp(40px,7vw,76px);
        line-height:1.04;
        font-weight:550;
        letter-spacing:-.055em;
        margin:64px 0 24px
    }
    p{color:var(--muted);max-width:670px}
    a{color:var(--accent)}
    section{
        border:1px solid #28382c;
        background:var(--panel);
        padding:32px;
        margin-top:32px;
        border-radius:12px
    }
    .label{
        font:12px ui-monospace,monospace;
        letter-spacing:.12em;
        color:var(--muted)
    }
    strong{
        display:block;
        font:72px ui-monospace,monospace;
        color:var(--accent);
        margin:12px 0
    }
    button,.button{
        display:inline-block;
        border:0;
        background:var(--accent);
        color:#071009;
        padding:12px 20px;
        border-radius:6px;
        font:600 15px system-ui;
        cursor:pointer;
        text-decoration:none
    }
    form{display:grid;gap:12px}
    input{
        background:var(--bg);
        color:var(--text);
        border:1px solid #425347;
        border-radius:6px;
        padding:12px;
        font:inherit
    }
    button{justify-self:start}
    footer{margin-top:48px;color:var(--muted);font-size:13px}
    #kiln-live-status{
        position:fixed;
        right:16px;
        bottom:8px;
        padding:6px 12px;
        border:1px solid #28382c;
        border-radius:20px;
        background:var(--bg);
        font-size:12px;
        z-index:1
    }
    a:focus-visible,button:focus-visible,input:focus-visible{
        outline:2px solid var(--accent);
        outline-offset:4px
    }
    .shell{display:flex;gap:56px;max-width:1200px;margin:0 auto;padding:0 40px;align-items:flex-start}
    .shell main{flex:1 1 auto;margin:0;max-width:860px;padding:64px 0 96px}
    .sidenav{
        position:sticky;
        top:0;
        flex:0 0 216px;
        width:216px;
        min-height:100vh;
        padding:48px 24px 48px 0;
        display:grid;
        align-content:start;
        gap:4px;
        border-right:1px solid #28382c
    }
    .sidenav__brand{
        font:12px ui-monospace,monospace;
        letter-spacing:.12em;
        color:var(--accent);
        margin-bottom:20px
    }
    .sidenav nav{display:grid;gap:4px}
    .sidenav a{
        color:var(--muted);
        text-decoration:none;
        padding:10px 14px;
        border-radius:6px;
        font:600 14px/1.2 system-ui
    }
    .sidenav a:hover{background:var(--panel);color:var(--text)}
    .sidenav a[aria-current=page]{background:var(--accent);color:#071009}
    @media(max-width:760px){
        .shell{flex-direction:column;gap:0;padding:0 20px}
        .sidenav{
            position:static;
            flex:none;
            width:auto;
            min-height:0;
            border-right:0;
            border-bottom:1px solid #28382c;
            padding:20px 0;
            grid-auto-flow:column;
            align-items:center;
            justify-content:start;
            overflow-x:auto
        }
        .sidenav__brand{margin:0 16px 0 0}
        .sidenav nav{display:flex;gap:8px}
        .shell main{padding:40px 0 64px}
    }
    """
}
