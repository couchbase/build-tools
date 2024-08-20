Uploading images to RHCC
========================

This is complicated, because RHCC's upload procedure is a moving target
and they lack basic automation features. The following things seem to be
*usually* true, although it has been incredibly inconsistent over time.
It also seems to work somewhat better for multi-arch images, so this
suggests we should switch ASAP to using only those.

# Background

A docker image has a SHA. (A multi-arch image actually has three SHAs --
one for the actual amd64 image, one for the actual arm64 image, and a
third for the manifest-list which binds those two together. When
discussing an "image SHA" for a multi-arch image, I am referring to the
latter.)

Docker images can also have a tag, such as :3.0.5. This is a N:1
relationship - multiple tag can refer to the same image SHA in a given
context.

# What we want

On RHCC, each version of a product has three tags: `:VERSION`,
`:VERSION-xx`, and `:VERSION-rhcc`, where -xx is a monotonically
increasing "rebuild number", and -rhcc is literal. So for instance, on
RHCC, for Couchbase Server 7.6.1, there are

    registry.connect.redhat.com/couchbase/server:7.6.1
    registry.connect.redhat.com/couchbase/server:7.6.1-1
    registry.connect.redhat.com/couchbase/server:7.6.1-rhcc

which all point to the same image.

We need to rebuild this image on a regular basis (monthly?) to pick up
security updates in the ubi8 base image. This results in a new image SHA
that we upload to RHCC. We want this new image to be associated with the
tags

    registry.connect.redhat.com/couchbase/server:7.6.1
    registry.connect.redhat.com/couchbase/server:7.6.1-2
    registry.connect.redhat.com/couchbase/server:7.6.1-rhcc

while the old tag :7.6.1-1 continues to point to the original image. In
other words, the tags without a "rebuild number" should *move* from
image to image, so that `docker pull
registry.connect.redhat.com/couchbase/server:7.6.1` always pulls the
image with the most recent security updates.

# Why it's so complicated

There are four contexts in Red Hat-land where tags are mapped to image
SHAs:

1. `quay.io/redhat-isv-containers/xxxxxxx`, a Docker registry that we
   upload new images to when publishing.
2. https://connect.redhat.com/component/view/xxxxxxx, the Connect web UI
   for seeing what images exist; what tags they're associated with; and
   whether those images are Published, meaning that they're available
   for public use.
3. https://catalog.redhat.com/software/containers/xxxxxx, the public web
   interface where customers can see what tags exist.
4. https://registry.connect.redhat.com/couchbase/xxxxxxx, the public
   Docker registry where customers pull our images.

After many hours of experimentation, at this time (July 17, 2024) the
only rules I can find that are *usually* true are:

- If an image is Published, then the set of tags in (2) and (3) above
  will match.
- If an image is Published, then the set of tags we uploaded to (1)
  will match the set available for customers at (4). This includes if
  we upload a new tag to an existing Published image; it will
  immediately be available for `docker pull` via the public registry.
- If the *project* at (2) has Auto-Publish enabled (which I believe we
  do for all our projects), then when we run `preflight` for an image,
  that image will become Published.

No other relationships are guaranteed:

- If we upload a *new* image with a *new* tag to (1) and then run
  `preflight` (which triggers Auto-Publish), then most of the time the
  image and tag will appear in (2), (3), and (4) as expected.
- However if we upload a *new* image with an *existing* tag to (1) and
  then run `preflight`, all we have reasonable confidence of is that the
  corresponding image and tag will become available at (4). In (2) and
  (3), the existing tag may simply disappear; it may remain associated
  with the older image it was previously pointing to; or it may update
  to be associated with the new image.
  - Note: in this scenario, when we upload a new image (which by
    definition cannot be Published) with an existing tag, that tag
    *immediately* is no longer pullable from (4), although the tag will
    likely still be visible (referencing whatever image it previously
    did) at (2) and (3). This can break customers.
- If we upload an *existing* Published image with a *new* tag to (1),
  all we have reasonable confidence of is that pulling that new tag at
  (4) will pull the image. In (2) and (3), the new tag may or may not
  appear at all, although if it does, it will probably be associated
  with the correct image.
- If we upload an *existing* Published image with an *existing* tag
  (that is associated with a different image) to (1), similarly, all we
  have reasonable confidence of is that pulling that existing tag at (4)
  will now pull the updated image. In (2) and (3), the existing tag may
  disappear; it may continue to point to the older image SHA; or it
  occasionally will do the right thing and start pointing at the new
  image SHA.

Further notes:

- The *only* control over tags we have is via pushing images to (1). We
  cannot delete nor add tags via the Connect UI (2). The only option we
  have via (2) is to Unpublish and then Delete the entire image, which
  will also wipe out all tags pointing to that image.
- The Connect UI (2) has a "Sync Tags" link on each image. This is
  supposed to update the set of tags associated with that image by
  pulling them from (1) and then reflecting them to (3). However, this
  does not appear to work reliably, especially as regards removing tags
  that no longer point to that image.

Upshot
======

Given all the above, the way that rhcc-certify-and-publish.sh works is:

1. It first ensures that the `:VERSION-xx` tag is *new*, not previously
   known on RHCC, by using `skopeo inspect` on the upload site (1).

   If the image is already known, it aborts, because the whole point of
   the rebuild number is that it is unique and should only ever point to
   a single image SHA. Also, if we attempt to re-`preflight` an
   already-existing image, it fails.

2. It also ensures that the image SHA it is going to push is not
   previously known on RHCC, for the same basic reasons - things are far
   more likely to go wrong when attempting to change existing
   image<->tag associations than when dealing with entirely new
   images/tags.

3. It then uploads the new image to the `:VERSION-xx` tag. This should
   not have any customer-visible impact since that tag would not have
   been in use by anyone.

4. It runs `preflight` on this new tag.

5. It polls the public Docker registry (4) until the new tag is
   available (ensuring that Auto-Publish worked).

6. Finally it re-uploads the same new image to to upload site (1) with
   the possibly-existing `:VERSION` and `:VERSION-rhcc` tags.

   This *should* at least result in those tags becoming visible at the
   public registry (4), which is the most important thing. If it happens
   to cause the public web UI (3) to reflect the new tag associations,
   great.
