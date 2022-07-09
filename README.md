# Defdo.DDNS

Yes, this is another DDNS project, We don't want to reinvent the wheel, but the options out there were not working properly, and because we need to fix the issue asap, we choose to build another choice.

If you want we improve the solution please feel free to give us feedback or make a PR.

### Why?

We have a home lab, and our `IP` is not static; our domain is at Cloudflare, and they provide an API to update the `DNS` records.

We have a `UDM Pro` router which uses [unifios-utilities](https://github.com/unifi-utilities/unifios-utilities) to preserve data after reboot. We know that `UDM Pro` uses `podman` to run docker images.

We create this project with the goal of
 * Use elixir since it is our primary language.
 * We want a `GenServer` to keep monitoring when the `IP` changes to update the `DNS` records.
 * We must create a multi-platform docker image to be deployed with `podman` on our `UDM Pro` because it runs 24 x 7.

## Using it

For our use case we put the script at `/mnt/data/on_boot.d/30-defdo-ddns.sh`.

```bash
vi /mnt/data/on_boot.d/30-defdo-ddns.sh
```

The content of the script looks like

```bash
#!/bin/sh
CONTAINER=defdo-ddns

# Starts a defdo ddns container that is deleted after it is stopped.
if podman container exists "$CONTAINER"; then
  podman start "$CONTAINER"
else
  podman run -i -d --rm \
    --net=host \
    --name "$CONTAINER" \
    --security-opt=no-new-privileges \
    -e CLOUDFLARE_API_TOKEN=<REPLACE_WITH_YOUR_TOKEN> \
    -e CLOUDFLARE_DOMAIN=<YOUR_DOMAIN> \
    -e CLOUDFLARE_SUBDOMAINS=<YOUR_SUBDOMAINS_COMMA_SEPARATED> \
    paridin/defdo_ddns
fi
```
Remember to update the environment variables.

# What is next?

 - [ ] Deliver a notification if the update is not possible.

## Contributing to this project

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `defdo_ddns` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:defdo_ddns, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/defdo_ddns>.


# Another way to contrib (Mexico Only)

> If you love the open-source as we do, or you are tired of your current Mobile Services Provider, or maybe you want to help us grow. One of our goals is to contribute with persons that share our feelings, making a win-win. We are building a telephony brand in Mexico focused on developers. Want to learn with us? Join the [defdo](https://shop.defdo.dev/?dcode=defdo_ddns&scode=github) community, and enjoy not only the telephony!.

