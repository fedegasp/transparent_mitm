from mitmproxy import command, ctx, flow


class PinMarked:

    @command.command("pin.marked")
    def pin_marked(self) -> None:
        """Pin all marked flows using server replay."""
        marked_flows: list[flow.Flow] = ctx.master.commands.call(
            "view.flows.resolve", "@marked"
        )

        if not marked_flows:
            ctx.log.warn("pin_marked: no marked flows found.")
            return

        ctx.options.server_replay_nopop = True
        ctx.options.server_replay_ignore_content = True
        ctx.master.commands.call("replay.server", marked_flows)

        ctx.log.info(f"pin_marked: {len(marked_flows)} flows pinned.")

    @command.command("pin.unpin")
    def unpin(self) -> None:
        """Remove the pin."""
        ctx.options.server_replay_nopop = False
        ctx.options.server_replay_ignore_content = False
        ctx.master.commands.call("replay.server.stop")
        ctx.log.info("pin_marked: replay removed.")


def running():
    ctx.log.info("pin_marked: P = pin | U = unpin")


addons = [PinMarked()]
