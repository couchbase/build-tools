Uploading images to RHCC
========================

This is complicated, because RHCC's upload procedure is a moving target
and they lack basic automation features. The following things seem to be
*usually* true, although it has been incredibly inconsistent over time.

# What we want

On RHCC, each version of a product has three tags: `:VERSION`,
`:VERSION-xx`, and `:VERSION-rhcc`, where -xx is a monotonically
increasing "rebuild number", and -rhcc is literal. So for instance, on
RHCC, for Couchbase Server 7.6.1, there are

    registry.connect.redhat.com/couchbase/server:7.6.1
    registry.connect.redhat.com/couchbase/server:7.6.1-1
    registry.connect.redhat.com/couchbase/server:7.6.1-rhcc

which all point to the same image, where "same image" seems to mean "the
same multi-architecture manifest".

(As an aside, we don't actually *want* the `:VERSION-xx` tag; however,
we *need* it, for reasons that will be explained below.)

We need to rebuild this image on a regular basis to pick up security
updates in the UBI base image. This results in a new image (more
specifically, a new multi-arch manifest) upload to RHCC. We want this
new image to be associated with the tags

    registry.connect.redhat.com/couchbase/server:7.6.1
    registry.connect.redhat.com/couchbase/server:7.6.1-2
    registry.connect.redhat.com/couchbase/server:7.6.1-rhcc

while the old tag :7.6.1-1 continues to point to the original image. In
other words, the tags without a "rebuild number" should *move* from
image to image, so that `docker pull
registry.connect.redhat.com/couchbase/server:7.6.1` always pulls the
image with the most recent security updates.

# Why it's so complicated

RHCC requires us to upload our images to a non-published site (specific
repositories on quay.io), and then "certify" them by running a tool
called `preflight`. Preflight posts the certification results to
something called "Pyxis", which in turn triggers auto-publish (which we
have enabled for all of our RHCC repositories).

The relationship between:

- what tags we have uploaded
- what tag we run `preflight` on
- what tags show up in their Partner Connect UI and in the public
  catalog
- what tags are actually available via `docker pull`

is inscrutable at best, and frequently seems completely random. Worse,
it's dynamic; what is true one minute may well not be true the next
minute, up to and including tags that were previously available via
`docker pull` suddenly no longer being there, or even image manifests
disappearing entirely from the Partner Connect UI. So far we have
absolute 100% confidence, backed by many years of experience, that
whatever seems to work today will no longer work at some point in the
future. Also, whatever we do, something will go catastrophically wrong
sooner or later. The best we can do is experiment at random and attempt
to find a working method that seems the least unstable.

A few things that currently seem to be true are:

- uploading a tag to quay.io that is already published will cause that
  tag to immediately become un-pullable
- running preflight against a tag (assuming it succeeds) will trigger
  auto-publish of that tag
- if you run preflight against a tag, and that image is also associated
  with other tags, you can't make any predictions about what will happen
  to those tags
- if a tag has been preflighted and successfully published, and you then
  re-upload that image associated with a new tag, then that new tag will
  also immediately become pullable
- running preflight on a tag, and the image associated with that tag is
  already published, preflight will fail

# So, the process

The sequence of operations that, as of today (August 28, 2025), appears
to work vaguely consistently is as follows:

- Create a completely new image manifest, every time. We do this by
  first creating the multi-arch image on build-docker that we want to
  publish, and then creating a trivial Dockerfile that looks like this:
```
FROM build-docker.couchbase.com/cb-rhcc/fooo:x.y.z
ARG CACHEBUST
```
- We pick a random number (literally).
- We use `docker buildx build --push --build-arg CACHEBUST=<random>` to
  build a new image manifest and push it to quay.io, associated with the
  `:VERSION-xx` tag which should be an entirely new, never-before-seen
  tag.
- Next, we run preflight against that tagged image.
- Assuming that succeeds, we poll the public registry to ensure that
  both the amd64 and arm64 images for this new tag become pullable, AND
  that they're associated with the same manifest (as identified by its
  sha256 digest).
- Now, we re-run `docker buildx build` with all the same arguments as
  before, including the *same* random number, but supply the `:VERSION`
  and `:VERSION-rhcc` (and possibly `:latest`) tags. Due to buildx's
  caching, this will push the exact same image manifest to quay.io
  associated with these new tags. Since the corresponding image is
  already published, in theory those new tags should immediately become
  pullable and pull the new image.
- Finally, we poll the public registry again waiting for the amd64 and
  arm64 images for all new tags become pullable, and that they're
  associated with the same new image manifest.

Note: most of the time, all these pullable tags will NOT appear in the
Partner Connect UI. The most common variant is that only the
`:VERSION-xx` tag shows up, but sometimes it's exactly the reverse.
Clicking "Sync Tags" sometimes helps, sometimes doesn't. The same is
true for the public catalog; there doesn't seem to be a consistent way
to ensure that it actually reflects reality.

# Random notes

Previously we used `skopeo copy` to upload the already-built image
directly from `build-docker.couchbase.com` to `quay.io`. This worked for
a while, but has been failing catastrophically for some time, often with
images disappearing entirely. I switched to `docker buildx build --push`
instead. I have no idea if skopeo was actually doing something "wrong"
or if it just did something slightly differently than RHCC wanted (I
know what I'd bet on, though).

The main reason we still want the `:VERSION-xx` tag is to ensure that we
can upload and preflight a new image successfully before pushing any
already-existing tags. If we did the more straightforward thing where we
just uploaded the `:VERSION` tag, then there would be a window of time
between pushing and preflight where the image would become un-pullable.
Worse, if anything went wrong (preflight failed, etc), the image would
*remain* un-pullable.
