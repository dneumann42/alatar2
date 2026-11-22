#!/usr/bin/env bash

alatar_checkout() {
    local name=$1 dest=$ALATAR_SOURCE_CACHE/$1
    local url=https://github.com/dneumann42/$name.git
    if [[ ! -e $dest ]]; then
        git clone --branch main --single-branch "$url" "$dest"
        return
    fi
    if [[ ! -d $dest/.git ]] ||
       [[ $(git -C "$dest" remote get-url origin) != "$url" ]] ||
       [[ $(git -C "$dest" symbolic-ref --short HEAD) != main ]] ||
       [[ -n $(git -C "$dest" status --porcelain) ]]; then
        echo "alatar: inspect the managed checkout at $dest" >&2
        return 1
    fi
    git -C "$dest" fetch origin main
    git -C "$dest" merge-base --is-ancestor HEAD FETCH_HEAD || {
        echo "alatar: local commits or divergent history at $dest" >&2
        return 1
    }
    git -C "$dest" merge --ff-only FETCH_HEAD
}
