from mitmproxy import command, ctx, flow


class PinMarked:

    @command.command("pin.marked")
    def pin_marked(self) -> None:
        """Pinna tutti i flow marcati usando server replay."""
        marked_flows: list[flow.Flow] = ctx.master.commands.call(
            "view.flows.resolve", "@marked"
        )

        if not marked_flows:
            ctx.log.warn("pin_marked: nessun flow marcato trovato.")
            return

        ctx.options.server_replay_nopop = True
        ctx.options.server_replay_ignore_content = True
        ctx.master.commands.call("replay.server", marked_flows)

        ctx.log.info(f"pin_marked: {len(marked_flows)} flow pinnati.")

    @command.command("pin.unpin")
    def unpin(self) -> None:
        """Rimuove il pin."""
        ctx.options.server_replay_nopop = False
        ctx.options.server_replay_ignore_content = False
        ctx.master.commands.call("replay.server.stop")
        ctx.log.info("pin_marked: replay rimosso.")


def running():
    ctx.log.info("pin_marked: P = pinna | U = rimuovi pin")


addons = [PinMarked()]
