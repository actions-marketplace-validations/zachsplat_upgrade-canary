# syntax=docker/dockerfile:1
ARG NODE_TAG=lts
FROM node:lts AS deps
FROM --platform=$BUILDPLATFORM node:lts-slim AS build
FROM docker.io/library/ubuntu:latest AS os
FROM ubuntu
FROM python:3-slim AS py
FROM python:3.14 AS pinned-minor
FROM node:${NODE_TAG} AS from-arg
FROM node:lts@sha256:3d27e5c11e57b6cb0b6a2c8a4a3d27e5c11e57b6cb0b6a2c8a4a3d27e5c11e57 AS digest-pinned
FROM deps AS reuse
FROM scratch
FROM alpine:3.22
FROM node:lts-alpine3.19 AS old-variant
