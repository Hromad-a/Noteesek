/// <reference path="../pb_data/types.d.ts" />

// Make attachment files protected: they can no longer be fetched by plain URL;
// a short-lived file token (obtained by the authenticated owner) is required.
migrate((app) => {
  const collection = app.findCollectionByNameOrId("attachments");
  const field = collection.fields.getByName("file");
  field.protected = true;
  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("attachments");
  const field = collection.fields.getByName("file");
  field.protected = false;
  app.save(collection);
});
