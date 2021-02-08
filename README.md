# Manual PIA VPN Connections for FreeNAS Jails

Setting up manual VPN connections to Private Internet Access can be a little confusing.  This repo contains a single script to setup a Wireguard connection to PIA quickly.  

## Usage
```
Usage:
  ./pia-wg.sh setup    - Create configuration files
  ./pia-wg.sh token    - Fetch an auth token with user/password
  ./pia-wg.sh pf_set   - setup port forwarding
  ./pia-wg.sh pf_clean - clean up portforwarding data
  ./pia-wg.sh pf_port  - last known port forwarding port
```

## Quickstart

1. Download `pia-wg.sh` into your jail
2. Run `pia-wg.sh setup`.  Automatically find the fastest region, exchange wireguard keys and create a wireguard configuration.
3. Copy `pia.conf` to `/usr/local/etc/wireguard`
4. Start your VPN connection
5. Done!

It looks like this:

```
# check your current IP
> curl icanhazip.com

# fetch the script into your FreeNAS jail
> curl -LO https://raw.githubusercontent.com/mostlygeek/pia-wg/main/pia-wg.sh
> chmod +x pia-wg.sh

# Setup and create configuration files
> ./pia-wg.sh setup
Please enter basic information
  PIA Username: pXXXXXXX
  PIA Password:
  Use portfowarding? [true]: true
Getting the server list... OK!
CA Toronto: 0.006924s
Panama (geo): 0.043789s

#
# two files will be created.  .settings.env, pia.conf

> cp pia.conf /usr/local/etc/wireguard/pia.conf
> wg-quick up pia
> curl icanhazip.com
```

## Using Port forwarding

__When running `pia-wg.sh setup` make sure use `true` when asked about port-forwarding.__

PIA port forwarding generally works like this.

1. Through an established VPN connection ...
2. Call the REST API on the wireguard server to request a port forward
3. Keep port forwarding active with a keep alive request at least every 15 minutes

There are three commands to make this easier:

1. `pia-wg.sh pf_set`
2. `pia-wg.sh pf_clean`
3. `pia-wg.sh pf_port`

Usage example:

```
# initial run creates a new .portforward.env
> ./pia-wg.sh pf_set
File: .portforward.env not found.  Creating a new one.
  - Fetching token from metaserver host ... Success!
  - Fetching payload/signature values from 10.44.128.1 ... Success!
  - Wrote new .portforward.env
  - Binding/Refreshing binding on port:49658 ... Success!


# ./pia-wg.sh pf_set again uses the cached values
# to keep the port forward alive.  This can be automated via a cronjob.

> ./pia-wg.sh pf_set
Loading cached settings from .portforward.env
  - Binding/Refreshing binding on port:49658 ... Success!

# the last known port can be printed with:
> ./pia-wg.sh pf_port
49658

# it can be used like this ...
> update-something.sh $(./pia-wg.sh pf_port)
```

### Port Forwarding Expiry

The port forwarding allocation expires every two months.  This means every few months the configuration needs to be redone.  This can be done like this:

```
# clean up the old settings
> ./pia-wg.sh pf_clean

# set up port forwarding again
> ./pia_wg.sh pf_set
```

This can be automated with a cronjob that runs `./pia-wg.sh pf_clean` every few weeks.  On the next run of `./pia-wg.sh pf_set` it will automatically create a new configuration file and set the port.

## Original Repo

Some of the code in this repo was adapted from PIA's official repo,  [pia-foss/manual-connections](https://github.com/pia-foss/manual-connections).  That code is less FreeBSD specific and organized differently.  I wanted a single script file that was easy to fetch and could run without any tweaks.

## License
This project is licensed under the [MIT (Expat) license](https://choosealicense.com/licenses/mit/), which can be found [here](/LICENSE).
