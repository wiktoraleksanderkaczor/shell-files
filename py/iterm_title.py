import iterm2

async def main(connection):
    app = await iterm2.async_get_app(connection)
    tab = app.current_terminal_window.current_tab
    title = await tab.async_get_variable("title")
    print(title or "")

iterm2.run_until_complete(main)
