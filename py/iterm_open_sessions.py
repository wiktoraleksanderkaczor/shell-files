import sys
import iterm2

async def main(connection):
    sessions = sys.argv[1:]
    app = await iterm2.async_get_app(connection)
    window = app.current_terminal_window
    for session_name in sessions:
        tab = await window.async_create_tab()
        await tab.async_set_title(session_name)
        session = tab.current_session
        await session.async_send_text(
            f"autossh -M 0 cloud-desktop -t 'zsh -i -c \"zellij attach -c \\\"{session_name}\\\"\"'\n"
        )

iterm2.run_until_complete(main)
